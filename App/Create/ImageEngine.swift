import CoreImage
import CoreImage.CIFilterBuiltins
import CoreML
import Foundation
import StableDiffusion
import SwiftUI
import UIKit

/// Everything needed for one image generation.
struct ImageRequest {
    var prompt: String
    var negativePrompt: String
    var steps: Int
    var guidance: Float
    var seed: UInt32
    /// Source image for image-to-image and masked edits.
    var source: UIImage?
    /// How far the result may move from `source` (0...1).
    var strength: Float
    /// White where the image may change. Requires `source`.
    var mask: UIImage?
}

enum ImageEngineError: LocalizedError {
    case noModel
    case noEncoder
    case filtered
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noModel: return "Load an image model first."
        case .noEncoder:
            return
                "This model has no image encoder (VAEEncoder), so it can only create images from text."
        case .filtered: return "The model's safety filter blocked this image."
        case .cancelled: return "Cancelled."
        }
    }
}

/// Runs Stable Diffusion models on the device with Core ML.
@MainActor
final class ImageEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case loading(String)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isGenerating = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressText = ""

    private var pipeline: (any StableDiffusionPipelineProtocol)?
    private var loaded: InstalledModel?
    private var pixelSize = CGSize(width: 512, height: 512)
    private var hasEncoder = false
    private var loadedSignature = ""
    private let cancelFlag = Flag()

    var loadedModelID: String? { loaded?.id }
    var canEdit: Bool { hasEncoder }
    var outputSize: CGSize { pixelSize }

    func unload() {
        pipeline?.unloadResources()
        pipeline = nil
        loaded = nil
        loadedSignature = ""
        state = .idle
    }

    func load(_ model: InstalledModel, settings: AppSettings) async {
        let units = settings.computeChoice.units(for: model)
        let lowMemory = settings.lowMemoryImages || model.isXL
        let useSafety = settings.useSafetyChecker
        let signature = "\(model.id)|\(units.rawValue)|\(lowMemory)|\(useSafety)"
        guard signature != loadedSignature else { return }

        unload()
        state = .loading(model.displayName)
        let directory = model.directory
        let isXL = model.isXL

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                () throws -> (any StableDiffusionPipelineProtocol, CGSize) in
                let configuration = MLModelConfiguration()
                configuration.computeUnits = units
                if isXL {
                    let pipeline = try StableDiffusionXLPipeline(
                        resourcesAt: directory, configuration: configuration,
                        reduceMemory: lowMemory)
                    try pipeline.loadResources()
                    let size = pipeline.outputPixelSize
                    return (pipeline, CGSize(width: size.width, height: size.height))
                } else {
                    let pipeline = try StableDiffusionPipeline(
                        resourcesAt: directory, controlNet: [], configuration: configuration,
                        disableSafety: !useSafety, reduceMemory: lowMemory)
                    try pipeline.loadResources()
                    let size = pipeline.outputPixelSize
                    return (pipeline, CGSize(width: size.width, height: size.height))
                }
            }.value
            pipeline = result.0
            pixelSize = result.1
            hasEncoder = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("VAEEncoder.mlmodelc").path)
            loaded = model
            loadedSignature = signature
            state = .ready(model.displayName)
        } catch {
            state = .failed(
                "Could not load \(model.displayName): \(error.localizedDescription)")
        }
    }

    func cancel() {
        cancelFlag.set(true)
    }

    func generate(_ request: ImageRequest, settings: AppSettings) async throws -> UIImage {
        guard let pipeline, let loaded else { throw ImageEngineError.noModel }
        if request.source != nil, !hasEncoder { throw ImageEngineError.noEncoder }

        let size = pixelSize
        let source = request.source.map { ImageTools.fill($0, size: size) }
        let mask = request.mask.map { ImageTools.fill($0, size: size) }

        var configuration = PipelineConfiguration(prompt: request.prompt)
        configuration.negativePrompt = request.negativePrompt
        configuration.stepCount = max(1, request.steps)
        configuration.guidanceScale = request.guidance
        configuration.seed = request.seed
        configuration.imageCount = 1
        configuration.schedulerType = .dpmSolverMultistepScheduler
        configuration.disableSafety = !settings.useSafetyChecker
        if let cgSource = source?.cgImage {
            configuration.startingImage = cgSource
            configuration.strength = min(0.99, max(0.05, request.strength))
        }
        if loaded.isXL {
            configuration.encoderScaleFactor = 0.13025
            configuration.decoderScaleFactor = 0.13025
            configuration.originalSize = Float32(size.width)
            configuration.targetSize = Float32(size.width)
        }

        cancelFlag.set(false)
        isGenerating = true
        progress = 0
        progressText = "Preparing…"
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isGenerating = false
            UIApplication.shared.isIdleTimerDisabled = false
        }

        let flag = cancelFlag
        let finalConfiguration = configuration
        let images = try await Task.detached(priority: .userInitiated) {
            [weak self] () throws -> [CGImage?] in
            try pipeline.generateImages(configuration: finalConfiguration) { step in
                let done = step.step + 1
                let total = max(1, step.stepCount)
                Task { @MainActor [weak self] in
                    self?.progress = Double(done) / Double(total)
                    self?.progressText = "Step \(done) of \(total)"
                }
                return !flag.get()
            }
        }.value

        if flag.get() { throw ImageEngineError.cancelled }
        guard let first = images.first, let cgImage = first else {
            throw ImageEngineError.filtered
        }
        var result = UIImage(cgImage: cgImage)
        if let source, let mask {
            result = ImageTools.blend(result, over: source, mask: mask) ?? result
        }
        return result
    }
}

/// Thread-safe boolean used to stop a running generation.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum ImageTools {
    /// Scales and centre-crops an image to exactly `size` pixels.
    static func fill(_ image: UIImage, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(
                x: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2)
            image.draw(in: CGRect(origin: origin, size: scaled))
        }
    }

    /// Keeps `top` where the mask is white and `bottom` where it is black,
    /// with a soft edge between them.
    static func blend(_ top: UIImage, over bottom: UIImage, mask: UIImage) -> UIImage? {
        guard let topCG = top.cgImage, let bottomCG = bottom.cgImage, let maskCG = mask.cgImage
        else { return nil }
        let extent = CGRect(x: 0, y: 0, width: topCG.width, height: topCG.height)

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = CIImage(cgImage: maskCG).clampedToExtent()
        blur.radius = Float(topCG.width) / 48
        guard let softMask = blur.outputImage?.cropped(to: extent) else { return nil }

        let filter = CIFilter.blendWithMask()
        filter.inputImage = CIImage(cgImage: topCG)
        filter.backgroundImage = CIImage(cgImage: bottomCG)
        filter.maskImage = softMask
        guard let output = filter.outputImage,
            let cgImage = CIContext().createCGImage(output, from: extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

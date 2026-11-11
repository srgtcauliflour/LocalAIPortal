import CoreML
import Foundation
import MLXLMCommon
import SwiftUI

enum ComputeChoice: String, CaseIterable, Identifiable {
    case auto
    case neuralEngine
    case gpu
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .neuralEngine: return "Neural Engine"
        case .gpu: return "GPU"
        case .all: return "All"
        }
    }

    func units(for model: InstalledModel) -> MLComputeUnits {
        switch self {
        case .auto: return model.phoneFriendly ? .cpuAndNeuralEngine : .cpuAndGPU
        case .neuralEngine: return .cpuAndNeuralEngine
        case .gpu: return .cpuAndGPU
        case .all: return .all
        }
    }
}

/// User preferences, stored in UserDefaults on the device.
@MainActor
final class AppSettings: ObservableObject {
    private static let defaults = UserDefaults.standard

    @Published var systemPrompt: String { didSet { Self.defaults.set(systemPrompt, forKey: "systemPrompt") } }
    @Published var temperature: Double { didSet { Self.defaults.set(temperature, forKey: "temperature") } }
    @Published var topP: Double { didSet { Self.defaults.set(topP, forKey: "topP") } }
    @Published var maxTokens: Int { didSet { Self.defaults.set(maxTokens, forKey: "maxTokens") } }
    @Published var repetitionPenalty: Double {
        didSet { Self.defaults.set(repetitionPenalty, forKey: "repetitionPenalty") }
    }

    @Published var chatModelID: String { didSet { Self.defaults.set(chatModelID, forKey: "chatModel") } }
    @Published var imageModelID: String { didSet { Self.defaults.set(imageModelID, forKey: "imageModel") } }

    @Published var computeChoice: ComputeChoice {
        didSet { Self.defaults.set(computeChoice.rawValue, forKey: "computeChoice") }
    }
    @Published var lowMemoryImages: Bool {
        didSet { Self.defaults.set(lowMemoryImages, forKey: "lowMemoryImages") }
    }
    /// Off by default: generated images are not passed through a model's
    /// bundled content filter unless the user turns this on.
    @Published var useSafetyChecker: Bool {
        didSet { Self.defaults.set(useSafetyChecker, forKey: "useSafetyChecker") }
    }

    init() {
        let d = Self.defaults
        systemPrompt = d.string(forKey: "systemPrompt") ?? "You are a helpful assistant."
        temperature = d.object(forKey: "temperature") as? Double ?? 0.7
        topP = d.object(forKey: "topP") as? Double ?? 0.95
        maxTokens = d.object(forKey: "maxTokens") as? Int ?? 1024
        repetitionPenalty = d.object(forKey: "repetitionPenalty") as? Double ?? 1.1
        chatModelID = d.string(forKey: "chatModel") ?? ""
        imageModelID = d.string(forKey: "imageModel") ?? ""
        computeChoice = ComputeChoice(rawValue: d.string(forKey: "computeChoice") ?? "") ?? .auto
        lowMemoryImages = d.bool(forKey: "lowMemoryImages")
        useSafetyChecker = d.bool(forKey: "useSafetyChecker")
    }

    var generateParameters: GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(temperature),
            topP: Float(topP),
            repetitionPenalty: repetitionPenalty > 1.0 ? Float(repetitionPenalty) : nil)
    }
}

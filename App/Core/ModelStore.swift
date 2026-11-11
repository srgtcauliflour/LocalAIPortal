import Foundation
import SwiftUI
import UIKit
import ZIPFoundation

/// A model that has been downloaded and is ready to load.
struct InstalledModel: Codable, Identifiable, Hashable {
    var id: String
    var repo: String
    var kind: ModelKind
    var variant: String
    /// Folder name under `Documents/Models`.
    var folder: String
    /// Path inside `folder` that holds the loadable files ("" for the folder itself).
    var resourcePath: String
    var bytes: Int64
    var isXL: Bool
    var phoneFriendly: Bool

    var displayName: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    var directory: URL {
        let base = Storage.models.appendingPathComponent(folder, isDirectory: true)
        return resourcePath.isEmpty
            ? base : base.appendingPathComponent(resourcePath, isDirectory: true)
    }
}

/// Locations on disk. Paths are rebuilt each launch because the app
/// container path can change between installs.
enum Storage {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var models: URL { ensure(documents.appendingPathComponent("Models", isDirectory: true)) }
    static var gallery: URL {
        ensure(documents.appendingPathComponent("Gallery", isDirectory: true))
    }
    static var chats: URL { documents.appendingPathComponent("chats.json") }
    static var installed: URL { models.appendingPathComponent("installed.json") }

    private static func ensure(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func size(of url: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// One in-flight download.
struct DownloadJob: Identifiable {
    let id: String
    let title: String
    var total: Int64
    var received: Int64 = 0
    var stage: String = "Downloading"
    var error: String?

    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
}

/// Keeps the list of installed models and runs downloads.
@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var installed: [InstalledModel] = []
    @Published private(set) var jobs: [DownloadJob] = []

    private let client = HFClient()
    private let downloader = FileDownloader()
    private var tasks: [String: Task<Void, Never>] = [:]

    init() {
        if let data = try? Data(contentsOf: Storage.installed),
            let saved = try? JSONDecoder().decode([InstalledModel].self, from: data)
        {
            installed = saved.filter { FileManager.default.fileExists(atPath: $0.directory.path) }
        }
        // Models are large and can be re-downloaded, so keep them out of iCloud backups.
        var folder = Storage.models
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    func models(_ kind: ModelKind) -> [InstalledModel] {
        installed.filter { $0.kind == kind }
    }

    func isInstalled(_ plan: InstallPlan) -> Bool {
        installed.contains { $0.id == plan.id }
    }

    func isDownloading(_ plan: InstallPlan) -> Bool {
        tasks[plan.id] != nil
    }

    func delete(_ model: InstalledModel) {
        let folder = Storage.models.appendingPathComponent(model.folder, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        installed.removeAll { $0.id == model.id }
        save()
    }

    func cancel(_ jobID: String) {
        tasks[jobID]?.cancel()
    }

    func dismiss(_ jobID: String) {
        jobs.removeAll { $0.id == jobID }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(installed) {
            try? data.write(to: Storage.installed, options: .atomic)
        }
    }

    private func update(_ id: String, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    // MARK: - Installing

    func install(_ plan: InstallPlan) {
        guard tasks[plan.id] == nil, !isInstalled(plan) else { return }
        jobs.removeAll { $0.id == plan.id }
        jobs.append(
            DownloadJob(
                id: plan.id,
                title: plan.repo.split(separator: "/").last.map(String.init) ?? plan.repo,
                total: plan.bytes))
        UIApplication.shared.isIdleTimerDisabled = true

        tasks[plan.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let model = try await self.run(plan)
                self.installed.removeAll { $0.id == model.id }
                self.installed.append(model)
                self.save()
                self.jobs.removeAll { $0.id == plan.id }
            } catch is CancellationError {
                self.jobs.removeAll { $0.id == plan.id }
            } catch let error as URLError where error.code == .cancelled {
                self.jobs.removeAll { $0.id == plan.id }
            } catch {
                self.update(plan.id) { $0.error = error.localizedDescription }
            }
            self.tasks[plan.id] = nil
            if self.tasks.isEmpty { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    private func run(_ plan: InstallPlan) async throws -> InstalledModel {
        let manager = FileManager.default
        let folder = Storage.models.appendingPathComponent(plan.folderName, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        var finished: Int64 = 0
        for file in plan.files {
            try Task.checkCancellation()
            let relative: String
            switch plan.packaging {
            case .files(let prefix): relative = String(file.path.dropFirst(prefix.count))
            case .zip: relative = file.name
            }
            let destination = folder.appendingPathComponent(relative)

            // Files that finished in an earlier attempt are kept, so a
            // failed download picks up where it stopped.
            let existing =
                (try? manager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
                .int64Value
            if existing == nil || existing != file.bytes {
                let base = finished
                let throttle = Throttle()
                let id = plan.id
                try await downloader.download(
                    client.downloadRequest(repo: plan.repo, path: file.path), to: destination
                ) { [weak self] bytes in
                    guard throttle.ready() else { return }
                    Task { @MainActor [weak self] in
                        self?.update(id) { $0.received = base + bytes }
                    }
                }
            }
            finished += file.bytes
            update(plan.id) { $0.received = finished }
        }

        if case .zip = plan.packaging, let archive = plan.files.first {
            update(plan.id) { $0.stage = "Unpacking" }
            let zipURL = folder.appendingPathComponent(archive.name)
            let target = folder.appendingPathComponent("unpacked", isDirectory: true)
            try await Task.detached(priority: .userInitiated) {
                let manager = FileManager.default
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                try manager.unzipItem(at: zipURL, to: target)
                try manager.removeItem(at: zipURL)
            }.value
        }

        var resourcePath = ""
        var isXL = false
        if plan.kind == .image {
            guard let found = Self.findImageResources(in: folder) else {
                try? manager.removeItem(at: folder)
                throw HFError.notRunnable(
                    "The download finished but it does not contain a compiled Core ML Stable Diffusion model (no Unet.mlmodelc)."
                )
            }
            resourcePath = found
            let resources =
                found.isEmpty ? folder : folder.appendingPathComponent(found, isDirectory: true)
            for required in ["vocab.json", "merges.txt"] {
                guard
                    manager.fileExists(atPath: resources.appendingPathComponent(required).path)
                else {
                    try? manager.removeItem(at: folder)
                    throw HFError.notRunnable(
                        "The model is missing \(required), so its text encoder cannot run.")
                }
            }
            isXL = manager.fileExists(
                atPath: resources.appendingPathComponent("TextEncoder2.mlmodelc").path)
        }

        return InstalledModel(
            id: plan.id, repo: plan.repo, kind: plan.kind, variant: plan.variant,
            folder: plan.folderName, resourcePath: resourcePath,
            bytes: Storage.size(of: folder), isXL: isXL,
            phoneFriendly: plan.kind == .chat || plan.isPhoneFriendly)
    }

    /// Finds the directory that holds `Unet.mlmodelc` (or its chunks) and
    /// returns its path relative to `folder`.
    private static func findImageResources(in folder: URL) -> String? {
        let root = folder.resolvingSymlinksInPath().pathComponents
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix("._") || url.path.contains("__MACOSX") { continue }
            if name == "Unet.mlmodelc" || name == "UnetChunk1.mlmodelc" {
                let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
                    .pathComponents
                guard parent.count >= root.count else { return "" }
                return parent.dropFirst(root.count).joined(separator: "/")
            }
        }
        return nil
    }
}

/// Limits how often download progress is pushed to the UI.
final class Throttle {
    private let lock = NSLock()
    private var last = Date.distantPast

    func ready() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) > 0.25 else { return false }
        last = now
        return true
    }
}

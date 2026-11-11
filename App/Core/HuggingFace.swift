import Foundation

/// The two kinds of model the app can run.
enum ModelKind: String, Codable, CaseIterable, Identifiable {
    case chat
    case image

    var id: String { rawValue }
    var title: String { self == .chat ? "Chat" : "Image" }
}

/// One search result from the Hugging Face model list.
struct HFModel: Decodable, Identifiable, Hashable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let tags: [String]?
}

/// One entry in a repository's file listing.
struct HFFile: Decodable, Hashable {
    struct LFS: Decodable, Hashable {
        let size: Int64?
    }

    let type: String
    let path: String
    let size: Int64?
    let lfs: LFS?

    var isFile: Bool { type == "file" }
    var bytes: Int64 { lfs?.size ?? size ?? 0 }
    var name: String { (path as NSString).lastPathComponent }
}

enum HFError: LocalizedError {
    case badResponse(Int)
    case notRunnable(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            if code == 401 || code == 403 {
                return "Hugging Face refused access (\(code)). This model may be gated: accept its terms on huggingface.co and add your access token in Settings."
            }
            return "Hugging Face returned an error (\(code))."
        case .notRunnable(let reason):
            return reason
        }
    }
}

/// Minimal client for the public Hugging Face Hub API. This is the only
/// part of the app that touches the network.
struct HFClient {
    static let host = "https://huggingface.co"

    var token: String? { Keychain.read("hf_token") }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw HFError.badResponse(http.statusCode)
        }
    }

    /// Search models that this app can run: MLX text models for chat,
    /// Core ML Stable Diffusion models for images.
    func search(_ query: String, kind: ModelKind) async throws -> [HFModel] {
        var components = URLComponents(string: "\(Self.host)/api/models")!
        var items = [
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "search", value: trimmed))
        }
        switch kind {
        case .chat:
            items.append(URLQueryItem(name: "filter", value: "mlx"))
            items.append(URLQueryItem(name: "pipeline_tag", value: "text-generation"))
        case .image:
            items.append(URLQueryItem(name: "filter", value: "coreml"))
        }
        components.queryItems = items

        let (data, response) = try await URLSession.shared.data(for: request(components.url!))
        try check(response)
        return try JSONDecoder().decode([HFModel].self, from: data)
    }

    /// Full recursive file listing of a repository, following pagination.
    func files(in repo: String) async throws -> [HFFile] {
        var all: [HFFile] = []
        var next: URL? = URL(string: "\(Self.host)/api/models/\(repo)/tree/main?recursive=true")
        var pages = 0
        while let url = next, pages < 50 {
            let (data, response) = try await URLSession.shared.data(for: request(url))
            try check(response)
            all += try JSONDecoder().decode([HFFile].self, from: data)
            next = Self.nextPage(from: response)
            pages += 1
        }
        return all.filter(\.isFile)
    }

    /// Parses `Link: <url>; rel="next"`.
    private static func nextPage(from response: URLResponse) -> URL? {
        guard let http = response as? HTTPURLResponse,
            let link = http.value(forHTTPHeaderField: "Link")
        else { return nil }
        for part in link.components(separatedBy: ",") where part.contains("rel=\"next\"") {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"),
                start < end
            else { continue }
            return URL(string: String(part[part.index(after: start) ..< end]))
        }
        return nil
    }

    /// Request for downloading one file from a repository.
    func downloadRequest(repo: String, path: String) -> URLRequest {
        let encoded = path.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return request(URL(string: "\(Self.host)/\(repo)/resolve/main/\(encoded)")!)
    }
}

// MARK: - Install plans

/// What needs downloading to install one model (or one variant of it).
struct InstallPlan: Identifiable, Hashable {
    enum Packaging: Hashable {
        /// Individual files, kept in the same relative layout.
        case files(stripPrefix: String)
        /// A single zip archive that is unpacked after download.
        case zip
    }

    let repo: String
    let kind: ModelKind
    let variant: String
    let files: [HFFile]
    let packaging: Packaging

    var id: String { repo + "#" + variant }
    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Split-einsum conversions run on the Neural Engine and are the ones
    /// built for iPhone. "Original" conversions target Mac GPUs.
    var isPhoneFriendly: Bool {
        let name = variant.lowercased()
        return name.contains("split_einsum") || name.contains("split-einsum")
            || name.contains("splitein")
    }

    /// Folder name used on disk.
    var folderName: String {
        let raw = kind == .chat ? repo : repo + "__" + variant
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

enum InstallPlanner {
    /// Works out what can be installed from a repository's file listing.
    static func plans(repo: String, kind: ModelKind, files: [HFFile]) throws -> [InstallPlan] {
        switch kind {
        case .chat: return [try chatPlan(repo: repo, files: files)]
        case .image: return try imagePlans(repo: repo, files: files)
        }
    }

    private static func chatPlan(repo: String, files: [HFFile]) throws -> InstallPlan {
        let wanted: Set<String> = ["safetensors", "json", "jinja", "txt", "model"]
        let root = files.filter { file in
            !file.path.contains("/")
                && wanted.contains((file.path as NSString).pathExtension.lowercased())
        }
        let hasConfig = root.contains { $0.path == "config.json" }
        let hasWeights = root.contains { $0.path.hasSuffix(".safetensors") }
        guard hasConfig, hasWeights else {
            throw HFError.notRunnable(
                "This repository is not in MLX format (it needs config.json and .safetensors weights at the top level). GGUF and PyTorch-only models are not supported yet."
            )
        }
        return InstallPlan(
            repo: repo, kind: .chat, variant: "MLX", files: root,
            packaging: .files(stripPrefix: ""))
    }

    private static func imagePlans(repo: String, files: [HFFile]) throws -> [InstallPlan] {
        var plans: [InstallPlan] = []

        // Folders that already hold compiled Core ML resources.
        var bases: [String] = []
        for file in files {
            for marker in ["Unet.mlmodelc/", "UnetChunk1.mlmodelc/"] {
                guard let range = file.path.range(of: marker) else { continue }
                let base = String(file.path[..<range.lowerBound])
                if !bases.contains(base) { bases.append(base) }
            }
        }
        for base in bases {
            let members = files.filter { $0.path.hasPrefix(base) }
            let label = base.isEmpty ? "compiled" : String(base.dropLast())
            plans.append(
                InstallPlan(
                    repo: repo, kind: .image, variant: label, files: members,
                    packaging: .files(stripPrefix: base)))
        }

        // Zip archives (the usual packaging for community conversions).
        for file in files where file.path.lowercased().hasSuffix(".zip") {
            let lower = file.path.lowercased()
            // Skip uncompiled packages and ControlNet add-ons.
            if lower.contains("packages") || lower.contains("controlnet") { continue }
            plans.append(
                InstallPlan(
                    repo: repo, kind: .image, variant: file.path, files: [file],
                    packaging: .zip))
        }

        guard !plans.isEmpty else {
            throw HFError.notRunnable(
                "No compiled Core ML Stable Diffusion files were found in this repository.")
        }
        return plans.sorted { a, b in
            if a.isPhoneFriendly != b.isPhoneFriendly { return a.isPhoneFriendly }
            return a.bytes < b.bytes
        }
    }
}

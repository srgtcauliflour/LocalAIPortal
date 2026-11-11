import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var store: ModelStore

    @State private var kind: ModelKind = .chat
    @State private var query = ""
    @State private var results: [HFModel] = []
    @State private var searching = false
    @State private var searchError: String?

    private let client = HFClient()

    private var suggestions: [String] {
        switch kind {
        case .chat: return ["abliterated", "uncensored", "dolphin", "Qwen3", "gemma", "Llama-3.2"]
        case .image:
            return ["stable-diffusion", "coreml-community", "split-einsum", "palettized", "xl", "anime"]
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(ModelKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if !store.jobs.isEmpty {
                    Section("Downloads") {
                        ForEach(store.jobs) { job in
                            JobRow(job: job)
                        }
                    }
                }

                Section("On this iPhone") {
                    let installed = store.models(kind)
                    if installed.isEmpty {
                        Text("Nothing downloaded yet.").foregroundStyle(.secondary)
                    }
                    ForEach(installed) { model in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName)
                            Text("\(model.repo) · \(Storage.format(model.bytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        let targets = offsets.map { installed[$0] }
                        for model in targets { store.delete(model) }
                    }
                }

                Section {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search Hugging Face", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { search() }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(suggestions, id: \.self) { word in
                                Button(word) {
                                    query = word
                                    search()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    if searching {
                        HStack {
                            ProgressView()
                            Text("Searching…").foregroundStyle(.secondary)
                        }
                    }
                    if let searchError {
                        Text(searchError).font(.footnote).foregroundStyle(.red)
                    }
                    ForEach(results) { model in
                        NavigationLink {
                            RepoView(repo: model.id, kind: kind)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.id)
                                Text("\(model.downloads ?? 0) downloads · \(model.likes ?? 0) likes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Find models")
                } footer: {
                    Text(
                        kind == .chat
                            ? "Shows MLX-format chat models. 4-bit versions of models up to about 8B parameters suit this iPhone best."
                            : "Shows Core ML Stable Diffusion models. Pick a split-einsum version: those are the ones built for iPhone."
                    )
                }
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: kind) { _, _ in
                results = []
                query = ""
                search()
            }
            .task {
                if results.isEmpty { search() }
            }
        }
    }

    private func search() {
        let text = query
        let wanted = kind
        searching = true
        searchError = nil
        Task {
            do {
                let found = try await client.search(text, kind: wanted)
                if wanted == kind { results = found }
            } catch {
                searchError = "Search needs an internet connection. \(error.localizedDescription)"
            }
            searching = false
        }
    }
}

private struct JobRow: View {
    @EnvironmentObject private var store: ModelStore
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.title)
                Spacer()
                if job.error == nil {
                    Button("Cancel", role: .destructive) { store.cancel(job.id) }
                        .buttonStyle(.borderless)
                } else {
                    Button("Dismiss") { store.dismiss(job.id) }
                        .buttonStyle(.borderless)
                }
            }
            if let error = job.error {
                Text(error).font(.footnote).foregroundStyle(.red)
                Text("Downloaded files are kept. Start the download again to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: job.fraction)
                Text(
                    "\(job.stage) · \(Storage.format(job.received)) of \(Storage.format(job.total))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Shows what can be installed from one Hugging Face repository.
struct RepoView: View {
    let repo: String
    let kind: ModelKind

    @EnvironmentObject private var store: ModelStore
    @State private var plans: [InstallPlan] = []
    @State private var loading = true
    @State private var message: String?

    var body: some View {
        List {
            if loading {
                HStack {
                    ProgressView()
                    Text("Reading file list…").foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message).foregroundStyle(.red)
            }
            ForEach(plans) { plan in
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.variant).font(.subheadline)
                    HStack(spacing: 8) {
                        Text(Storage.format(plan.bytes))
                        if kind == .image {
                            Text(plan.isPhoneFriendly ? "Built for iPhone" : "Mac-style, may be slow")
                                .foregroundStyle(plan.isPhoneFriendly ? Color.green : Color.orange)
                        } else if plan.bytes > 7_000_000_000 {
                            Text("May not fit in memory").foregroundStyle(Color.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if store.isInstalled(plan) {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    } else if store.isDownloading(plan) {
                        if let job = store.jobs.first(where: { $0.id == plan.id }) {
                            ProgressView(value: job.fraction)
                            Text(job.stage).font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            store.install(plan)
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Link(
                    "View on Hugging Face",
                    destination: URL(string: "\(HFClient.host)/\(repo)")!)
            } footer: {
                Text("Keep the app open while a model downloads. Models are several gigabytes, so Wi-Fi is best.")
            }
        }
        .navigationTitle(repo.split(separator: "/").last.map(String.init) ?? repo)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let files = try await HFClient().files(in: repo)
                plans = try InstallPlanner.plans(repo: repo, kind: kind, files: files)
            } catch {
                message = error.localizedDescription
            }
            loading = false
        }
    }
}

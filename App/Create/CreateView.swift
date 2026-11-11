import PhotosUI
import SwiftUI
import UIKit

struct CreateView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ModelStore
    @EnvironmentObject private var engine: ImageEngine
    @EnvironmentObject private var chatEngine: ChatEngine
    @EnvironmentObject private var gallery: GalleryStore

    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var steps = 20.0
    @State private var guidance = 7.5
    @State private var randomSeed = true
    @State private var seedText = "42"
    @State private var strength = 0.6

    @State private var pickerItem: PhotosPickerItem?
    @State private var source: UIImage?
    @State private var mask: UIImage?
    @State private var showingMaskEditor = false

    @State private var result: UIImage?
    @State private var resultItem: GalleryItem?
    @State private var lastSeed: UInt32?
    @State private var errorMessage: String?
    @State private var savedToPhotos = false

    private var models: [InstalledModel] { store.models(.image) }
    private var selected: InstalledModel? {
        models.first { $0.id == settings.imageModelID } ?? models.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if models.isEmpty {
                    ContentUnavailableView(
                        "No image model yet", systemImage: "photo.artframe",
                        description: Text(
                            "Open the Models tab and download an image model. After that, creating images works with no internet connection."
                        ))
                } else {
                    form
                }
            }
            .navigationTitle("Create")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        GalleryView()
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .accessibilityLabel("Gallery")
                }
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Model", selection: modelBinding) {
                    ForEach(models) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                TextField("Describe the image", text: $prompt, axis: .vertical)
                    .lineLimit(2 ... 6)
                TextField("Things to avoid (optional)", text: $negativePrompt, axis: .vertical)
                    .lineLimit(1 ... 3)
            }

            resultSection

            Section {
                generateControls
            }

            Section("Start from a photo") {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(source == nil ? "Choose photo" : "Change photo", systemImage: "photo")
                }
                if let source {
                    HStack(spacing: 12) {
                        Image(uiImage: source)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 6) {
                            Button(mask == nil ? "Paint area to change" : "Repaint area") {
                                showingMaskEditor = true
                            }
                            Button("Remove photo", role: .destructive) {
                                self.source = nil
                                mask = nil
                                pickerItem = nil
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    VStack(alignment: .leading) {
                        Text("Change amount: \(Int(strength * 100))%")
                        Slider(value: $strength, in: 0.1 ... 0.95)
                    }
                    if mask != nil {
                        Label("Only the painted area will change", systemImage: "paintbrush.pointed")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Options") {
                VStack(alignment: .leading) {
                    Text("Steps: \(Int(steps))")
                    Slider(value: $steps, in: 4 ... 50, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Prompt strength: \(guidance, specifier: "%.1f")")
                    Slider(value: $guidance, in: 1 ... 15, step: 0.5)
                }
                Toggle("Random seed", isOn: $randomSeed)
                if !randomSeed {
                    TextField("Seed", text: $seedText)
                        .keyboardType(.numberPad)
                }
                if let lastSeed {
                    Button("Reuse last seed (\(String(lastSeed)))") {
                        randomSeed = false
                        seedText = String(lastSeed)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                    let image = UIImage(data: data)
                {
                    source = image
                    mask = nil
                }
            }
        }
        .sheet(isPresented: $showingMaskEditor) {
            if let source {
                MaskEditor(
                    image: ImageTools.fill(source, size: engine.outputSize),
                    outputSize: engine.outputSize
                ) { mask = $0 }
            }
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { selected?.id ?? "" },
            set: { settings.imageModelID = $0 })
    }

    @ViewBuilder
    private var resultSection: some View {
        if let result {
            Section {
                Image(uiImage: result)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .listRowInsets(EdgeInsets())
                HStack {
                    Button {
                        UIImageWriteToSavedPhotosAlbum(result, nil, nil, nil)
                        savedToPhotos = true
                    } label: {
                        Label(
                            savedToPhotos ? "Saved" : "Save to Photos",
                            systemImage: "square.and.arrow.down")
                    }
                    Spacer()
                    if let resultItem {
                        ShareLink(item: resultItem.url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var generateControls: some View {
        switch engine.state {
        case .loading(let name):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading \(name)…")
                }
                Text("The first load of a model can take a few minutes while iOS prepares it for this phone. Later loads are much faster.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        default:
            if engine.isGenerating {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: engine.progress)
                    HStack {
                        Text(engine.progressText).font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel", role: .destructive) { engine.cancel() }
                            .buttonStyle(.borderless)
                    }
                }
            } else {
                Button {
                    generate()
                } label: {
                    Label("Generate", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if case .failed(let message) = engine.state {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func generate() {
        guard let model = selected else { return }
        errorMessage = nil
        savedToPhotos = false
        let seed: UInt32 = randomSeed ? UInt32.random(in: 0 ... UInt32.max) : (UInt32(seedText) ?? 42)
        let request = ImageRequest(
            prompt: prompt, negativePrompt: negativePrompt, steps: Int(steps),
            guidance: Float(guidance), seed: seed, source: source, strength: Float(strength),
            mask: source == nil ? nil : mask)

        Task {
            // Only one large model fits comfortably in memory at a time.
            chatEngine.unload()
            await engine.load(model, settings: settings)
            guard case .ready = engine.state else { return }
            do {
                let image = try await engine.generate(request, settings: settings)
                result = image
                lastSeed = seed
                resultItem = gallery.add(image)
            } catch ImageEngineError.cancelled {
                // Nothing to show.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

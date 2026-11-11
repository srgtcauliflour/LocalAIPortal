import SwiftUI
import UIKit

struct GalleryItem: Identifiable, Hashable {
    let url: URL
    var id: String { url.lastPathComponent }
}

/// Generated images, saved as PNG files inside the app.
@MainActor
final class GalleryStore: ObservableObject {
    @Published private(set) var items: [GalleryItem] = []

    init() {
        reload()
    }

    func reload() {
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: Storage.gallery, includingPropertiesForKeys: nil)) ?? []
        items = urls.filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(GalleryItem.init)
    }

    @discardableResult
    func add(_ image: UIImage) -> GalleryItem? {
        guard let data = image.pngData() else { return nil }
        let name = String(format: "%.0f.png", Date().timeIntervalSince1970 * 1000)
        let url = Storage.gallery.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        let item = GalleryItem(url: url)
        items.insert(item, at: 0)
        return item
    }

    func delete(_ item: GalleryItem) {
        try? FileManager.default.removeItem(at: item.url)
        items.removeAll { $0.id == item.id }
    }
}

struct GalleryView: View {
    @EnvironmentObject private var gallery: GalleryStore
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]

    var body: some View {
        ScrollView {
            if gallery.items.isEmpty {
                ContentUnavailableView(
                    "No images yet", systemImage: "photo.on.rectangle",
                    description: Text("Images you create are kept here on your device."))
                    .padding(.top, 80)
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(gallery.items) { item in
                    NavigationLink(value: item) {
                        Thumbnail(url: item.url)
                    }
                }
            }
            .padding(4)
        }
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: GalleryItem.self) { item in
            GalleryDetail(item: item)
        }
    }
}

private struct Thumbnail: View {
    let url: URL

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct GalleryDetail: View {
    let item: GalleryItem
    @EnvironmentObject private var gallery: GalleryStore
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false

    var body: some View {
        VStack {
            if let image = UIImage(contentsOfFile: item.url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                Spacer()
                HStack(spacing: 28) {
                    Button {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        saved = true
                    } label: {
                        Label(saved ? "Saved" : "Save to Photos", systemImage: "square.and.arrow.down")
                    }
                    ShareLink(item: item.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        gallery.delete(item)
                        dismiss()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .labelStyle(.iconOnly)
                .font(.title2)
                .padding()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

import SwiftUI

@main
struct LocalAIPortalApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var store = ModelStore()
    @StateObject private var chats = ChatStore()
    @StateObject private var chatEngine = ChatEngine()
    @StateObject private var imageEngine = ImageEngine()
    @StateObject private var gallery = GalleryStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                ChatView()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                CreateView()
                    .tabItem { Label("Create", systemImage: "photo.artframe") }
                ModelsView()
                    .tabItem { Label("Models", systemImage: "square.and.arrow.down") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .environmentObject(settings)
            .environmentObject(store)
            .environmentObject(chats)
            .environmentObject(chatEngine)
            .environmentObject(imageEngine)
            .environmentObject(gallery)
        }
    }
}

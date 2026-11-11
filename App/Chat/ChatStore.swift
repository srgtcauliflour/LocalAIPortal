import Foundation
import SwiftUI

struct ChatMessage: Codable, Identifiable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    var id = UUID()
    var role: Role
    var text: String
}

struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var title = "New chat"
    var messages: [ChatMessage] = []
    var updated = Date()
}

/// Saved conversations, stored as a JSON file on the device.
@MainActor
final class ChatStore: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID?

    init() {
        if let data = try? Data(contentsOf: Storage.chats),
            let saved = try? JSONDecoder().decode([Conversation].self, from: data)
        {
            conversations = saved
        }
        currentID = conversations.first?.id
        if currentID == nil { newConversation() }
    }

    var current: Conversation? {
        conversations.first { $0.id == currentID }
    }

    func newConversation() {
        // Reuse an existing empty chat rather than piling up blanks.
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            currentID = empty.id
            return
        }
        let conversation = Conversation()
        conversations.insert(conversation, at: 0)
        currentID = conversation.id
        save()
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = conversations.first?.id }
        if currentID == nil { newConversation() }
        save()
    }

    func append(_ message: ChatMessage, to id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.append(message)
        conversations[index].updated = Date()
        if conversations[index].title == "New chat", message.role == .user {
            conversations[index].title = String(message.text.prefix(40))
        }
        save()
    }

    /// Replaces the text of a message while a reply streams in.
    func setText(_ text: String, message: UUID, in id: UUID, persist: Bool) {
        guard let index = conversations.firstIndex(where: { $0.id == id }),
            let position = conversations[index].messages.firstIndex(where: { $0.id == message })
        else { return }
        conversations[index].messages[position].text = text
        if persist { save() }
    }

    func removeMessage(_ message: UUID, in id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages.removeAll { $0.id == message }
        save()
    }

    func save() {
        if let data = try? JSONEncoder().encode(conversations) {
            try? data.write(to: Storage.chats, options: .atomic)
        }
    }
}

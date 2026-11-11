import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import SwiftUI
import Tokenizers

/// Runs chat models on the device with MLX.
@MainActor
final class ChatEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case loading(String)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isGenerating = false
    @Published private(set) var tokensPerSecondText = ""

    private var container: ModelContainer?
    private var session: ChatSession?
    private var sessionConversation: UUID?
    private var sessionMessageCount = 0
    private var generation: Task<Void, Never>?
    private(set) var loadedModelID: String?

    func unload() {
        generation?.cancel()
        generation = nil
        session = nil
        container = nil
        loadedModelID = nil
        sessionConversation = nil
        isGenerating = false
        state = .idle
        Memory.clearCache()
    }

    func load(_ model: InstalledModel) async {
        guard loadedModelID != model.id else { return }
        unload()
        state = .loading(model.displayName)
        // Keep MLX's buffer cache small so memory goes to the model itself.
        Memory.cacheLimit = 32 * 1024 * 1024
        do {
            let loaded = try await LLMModelFactory.shared.loadContainer(
                from: model.directory, using: #huggingFaceTokenizerLoader())
            container = loaded
            loadedModelID = model.id
            state = .ready(model.displayName)
        } catch {
            state = .failed(
                "Could not load \(model.displayName): \(error.localizedDescription)")
        }
    }

    func stop() {
        generation?.cancel()
    }

    /// Sends the last user message of `conversation` and streams the reply
    /// into a new assistant message in `store`.
    func reply(in conversationID: UUID, store: ChatStore, settings: AppSettings) {
        guard let container, !isGenerating,
            let conversation = store.conversations.first(where: { $0.id == conversationID }),
            let prompt = conversation.messages.last, prompt.role == .user
        else { return }

        let earlier = Array(conversation.messages.dropLast())

        // Reuse the live session (and its cache) when this is simply the next
        // turn of the same conversation; otherwise rebuild from saved history.
        if session == nil || sessionConversation != conversationID
            || sessionMessageCount != earlier.count
        {
            let history: [Chat.Message] = earlier.map {
                $0.role == .user ? .user($0.text) : .assistant($0.text)
            }
            let system = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            session = ChatSession(
                container,
                instructions: system.isEmpty ? nil : system,
                history: history,
                generateParameters: settings.generateParameters)
            sessionConversation = conversationID
        }
        guard let session else { return }
        session.generateParameters = settings.generateParameters
        let instructions = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        session.instructions = instructions.isEmpty ? nil : instructions

        let reply = ChatMessage(role: .assistant, text: "")
        store.append(reply, to: conversationID)
        isGenerating = true
        tokensPerSecondText = ""

        generation = Task { [weak self] in
            var text = ""
            var failure: String?
            let started = Date()
            var pieces = 0
            do {
                for try await chunk in session.streamResponse(to: prompt.text) {
                    text += chunk
                    pieces += 1
                    store.setText(text, message: reply.id, in: conversationID, persist: false)
                }
            } catch is CancellationError {
                // Stopped by the user; keep what was generated.
            } catch {
                failure = error.localizedDescription
            }

            guard let self else { return }
            if let failure, text.isEmpty {
                store.setText(
                    "⚠️ " + failure, message: reply.id, in: conversationID, persist: true)
                // The session no longer matches the saved history; rebuild next time.
                self.session = nil
            } else if text.isEmpty {
                store.removeMessage(reply.id, in: conversationID)
                self.session = nil
            } else {
                store.setText(text, message: reply.id, in: conversationID, persist: true)
                self.sessionMessageCount = earlier.count + 2
                if Task.isCancelled { self.session = nil }
            }
            let seconds = Date().timeIntervalSince(started)
            if pieces > 0, seconds > 0 {
                self.tokensPerSecondText = String(
                    format: "%.0f chunks/s", Double(pieces) / seconds)
            }
            self.isGenerating = false
            self.generation = nil
        }
    }
}

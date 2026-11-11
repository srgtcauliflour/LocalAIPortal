import SwiftUI
import UIKit

struct ChatView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: ModelStore
    @EnvironmentObject private var chats: ChatStore
    @EnvironmentObject private var engine: ChatEngine
    @EnvironmentObject private var imageEngine: ImageEngine

    @State private var draft = ""
    @State private var showingHistory = false
    @FocusState private var inputFocused: Bool

    private var models: [InstalledModel] { store.models(.chat) }
    private var selected: InstalledModel? {
        models.first { $0.id == settings.chatModelID } ?? models.first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if models.isEmpty {
                    ContentUnavailableView(
                        "No chat model yet", systemImage: "bubble.left.and.bubble.right",
                        description: Text(
                            "Open the Models tab and download a chat model. After that, chatting works with no internet connection."
                        ))
                } else {
                    messages
                    statusBar
                    inputBar
                }
            }
            .navigationTitle(chats.current?.title ?? "Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Chat history")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    modelMenu
                    Button {
                        chats.newConversation()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .sheet(isPresented: $showingHistory) { HistorySheet() }
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(models) { model in
                Button {
                    settings.chatModelID = model.id
                    Task { await load(model) }
                } label: {
                    if model.id == selected?.id {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                }
            }
            if engine.loadedModelID != nil {
                Divider()
                Button("Unload model", role: .destructive) { engine.unload() }
            }
        } label: {
            Image(systemName: "cpu")
        }
        .accessibilityLabel("Choose chat model")
        .disabled(models.isEmpty || engine.isGenerating)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chats.current?.messages ?? []) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chats.current?.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: chats.currentID) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        switch engine.state {
        case .loading(let name):
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading \(name)…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
                .padding(.vertical, 6)
        default:
            if !engine.tokensPerSecondText.isEmpty, !engine.isGenerating {
                Text(engine.tokensPerSecondText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(selected?.displayName ?? "")", text: $draft, axis: .vertical)
                .lineLimit(1 ... 6)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .focused($inputFocused)

            if engine.isGenerating {
                Button {
                    engine.stop()
                } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 32))
                }
                .accessibilityLabel("Stop")
            } else {
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .accessibilityLabel("Send")
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func load(_ model: InstalledModel) async {
        // Only one large model fits comfortably in memory at a time.
        imageEngine.unload()
        await engine.load(model)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let model = selected, let conversation = chats.currentID else {
            return
        }
        draft = ""
        chats.append(ChatMessage(role: .user, text: text), to: conversation)
        Task {
            if engine.loadedModelID != model.id { await load(model) }
            engine.reply(in: conversation, store: chats, settings: settings)
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: message.text, options: options))
            ?? AttributedString(message.text)
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Group {
                if message.text.isEmpty {
                    ProgressView()
                } else {
                    Text(rendered).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.role == .user
                    ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}

private struct HistorySheet: View {
    @EnvironmentObject private var chats: ChatStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(chats.conversations) { conversation in
                    Button {
                        chats.currentID = conversation.id
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(conversation.title).foregroundStyle(.primary)
                            Text(conversation.updated, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { chats.conversations[$0].id }
                    for id in ids { chats.delete(id) }
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

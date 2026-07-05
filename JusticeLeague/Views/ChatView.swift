import SwiftUI
import Supabase

@MainActor
@Observable
final class ChatModel {
    var messages: [ChatMessage] = []
    var loading = true
    var errorText: String?

    private var roster: [UUID: Member] = [:]
    private var channel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?
    private var db: SupabaseClient { SupabaseManager.client }

    func start() async {
        await loadRoster()
        await load()
        await subscribe()
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        if let channel {
            Task { await db.removeChannel(channel) }
        }
        channel = nil
    }

    private func loadRoster() async {
        let members = (try? await TriviaService.allMembers()) ?? []
        roster = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
    }

    func load() async {
        do {
            messages = try await TriviaService.messages()
            errorText = nil
        } catch {
            errorText = "Couldn't load the chat."
        }
        loading = false
    }

    // Live-append new messages via Postgres change feed.
    private func subscribe() async {
        let channel = db.channel("public:messages")
        self.channel = channel
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "messages")
        await channel.subscribe()
        listenTask = Task { [weak self] in
            for await change in inserts {
                guard let self else { return }
                if let row = try? change.decodeRecord(as: RealtimeMessageRow.self, decoder: JSONDecoder()) {
                    await self.append(row)
                }
            }
        }
    }

    private func append(_ row: RealtimeMessageRow) async {
        guard !messages.contains(where: { $0.id == row.id }) else { return }
        if roster[row.member_id] == nil { await loadRoster() }
        let sender = roster[row.member_id]
        let msg = ChatMessage(
            id: row.id,
            memberId: row.member_id,
            body: row.body,
            createdAt: SupabaseManager.flexibleDate(from: row.created_at) ?? Date(),
            member: sender.map { .init(displayName: $0.displayName, avatar: $0.avatar) }
        )
        messages.append(msg)
    }

    func send(_ text: String, from member: Member) async {
        let body = text.trimmed
        guard !body.isEmpty else { return }
        do {
            let msg = try await TriviaService.sendMessage(memberId: member.id, body: body)
            if !messages.contains(where: { $0.id == msg.id }) { messages.append(msg) }
        } catch {
            errorText = "Message failed to send."
        }
    }

    func delete(_ msg: ChatMessage) async {
        do {
            try await TriviaService.deleteMessage(id: msg.id)
            messages.removeAll { $0.id == msg.id }
        } catch {
            errorText = "Couldn't delete that message."
        }
    }
}

struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var model = ChatModel()
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    messageList
                    inputBar
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { StencilTitle("Comms", size: 20) } }
            .task {
                await model.start()
                await markRead()
            }
            .onDisappear { model.stop() }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.loading {
                        ProgressView().tint(Theme.cyan).padding(.top, 40)
                    } else if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { msg in
                        MessageRow(message: msg, isMine: msg.memberId == app.currentMember?.id) {
                            Task { await model.delete(msg) }
                        }
                        .id(msg.id)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                Task { await markRead() }
            }
            .onChange(of: model.loading) { _, isLoading in
                if !isLoading { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private let bottomAnchor = "chat-bottom"

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 34)).foregroundStyle(Theme.textDim)
            Text("No messages yet. Break the silence, soldier.")
                .font(Theme.label(14)).foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $draft, prompt: Text("Message the League…").foregroundColor(Theme.textDim), axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.surfaceHi)
                .foregroundStyle(Theme.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.line))

            Button {
                guard let m = app.currentMember else { return }
                let text = draft
                draft = ""
                Task { await model.send(text, from: m) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(draft.trimmed.isEmpty ? Theme.textDim : Theme.cyan)
            }
            .disabled(draft.trimmed.isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .top)
    }

    private func markRead() async {
        try? await TriviaService.markChatRead()
        app.chatUnread = 0
    }
}

// A single chat bubble. Mine = cyan, right-aligned; others = white card with sender.
struct MessageRow: View {
    let message: ChatMessage
    let isMine: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine { Spacer(minLength: 40) }
            if !isMine {
                AvatarBadge(avatar: Avatars.find(message.member?.avatar), size: 32)
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine {
                    Text(message.senderName)
                        .font(Theme.label(12, weight: .bold))
                        .foregroundStyle(Theme.tan)
                }
                Text(message.body)
                    .font(Theme.label(16, weight: .regular))
                    .foregroundStyle(isMine ? .black : Theme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(isMine ? Theme.cyan : Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: isMine ? 0 : 1))
                Text(timeLabel(message.createdAt))
                    .font(Theme.label(10, weight: .regular))
                    .foregroundStyle(Theme.textDim)
            }
            if !isMine { Spacer(minLength: 40) }
        }
        .contextMenu {
            if isMine {
                Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = Config.timeZone
        f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "MMM d, h:mm a"
        return f.string(from: date)
    }
}

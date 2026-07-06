import SwiftUI
import Supabase
import PhotosUI
import UIKit
import AVKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import QuickLook

// Records a voice message to a temp .m4a file.
@MainActor
@Observable
final class VoiceRecorder {
    var isRecording = false
    private var recorder: AVAudioRecorder?
    private(set) var fileURL: URL?

    var currentTime: TimeInterval { recorder?.currentTime ?? 0 }

    func requestPermissionAndStart() async -> Bool {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { return false }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default)
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        guard let rec = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        recorder = rec
        fileURL = url
        rec.record()
        isRecording = true
        return true
    }

    @discardableResult
    func stop() -> Data? {
        recorder?.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        guard let url = fileURL else { return nil }
        return try? Data(contentsOf: url)
    }

    func cancel() {
        recorder?.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
    }
}

@MainActor
@Observable
final class ChatModel {
    var messages: [ChatMessage] = []
    var reactionMap: [UUID: [MessageReaction]] = [:]
    var typingMembers: [UUID: String] = [:]
    var readTimes: [UUID: Date] = [:]
    var currentMemberId: UUID?
    var loading = true
    var sending = false
    var errorText: String?

    private var roster: [UUID: Member] = [:]
    private var typingSeq: [UUID: Int] = [:]
    private var channel: RealtimeChannelV2?
    private var listenTask: Task<Void, Never>?
    private var db: SupabaseClient { SupabaseManager.client }

    func start() async {
        await loadRoster()
        await load()
        await reloadReactions()
        await reloadReadTimes()
        await subscribe()
    }

    func reloadReadTimes() async {
        let rows = (try? await TriviaService.chatReadTimes()) ?? []
        readTimes = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            row.chat_last_read_at.map { (row.id, $0) }
        })
    }

    // "Seen" text under my most recent message, if others have read past it.
    func seenText(for message: ChatMessage) -> String? {
        guard let myId = currentMemberId, message.memberId == myId, messages.last?.id == message.id else { return nil }
        let count = readTimes.filter { $0.key != myId && $0.value >= message.createdAt }.count
        guard count > 0 else { return nil }
        return count == 1 ? "Seen" : "Seen by \(count)"
    }

    func sendTyping(name: String) {
        guard let id = currentMemberId, let channel else { return }
        Task {
            try? await channel.broadcast(event: "typing",
                                         message: ["member_id": .string(id.uuidString), "name": .string(name)])
        }
    }

    private func handleTyping(_ payload: [String: AnyJSON]) {
        guard let idStr = payload["member_id"]?.stringValue, let id = UUID(uuidString: idStr),
              let name = payload["name"]?.stringValue, id != currentMemberId else { return }
        typingMembers[id] = name
        let seq = (typingSeq[id] ?? 0) + 1
        typingSeq[id] = seq
        Task {
            try? await Task.sleep(for: .seconds(4))
            if typingSeq[id] == seq { typingMembers[id] = nil }
        }
    }

    func messageByID(_ id: UUID?) -> ChatMessage? {
        guard let id else { return nil }
        return messages.first { $0.id == id }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        if let channel { Task { await db.removeChannel(channel) } }
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

    private func subscribe() async {
        let channel = db.channel("public:chat")
        self.channel = channel
        let inserts = channel.postgresChange(InsertAction.self, schema: "public", table: "messages")
        let updates = channel.postgresChange(UpdateAction.self, schema: "public", table: "messages")
        let deletes = channel.postgresChange(DeleteAction.self, schema: "public", table: "messages")
        let reactIns = channel.postgresChange(InsertAction.self, schema: "public", table: "message_reactions")
        let reactUpd = channel.postgresChange(UpdateAction.self, schema: "public", table: "message_reactions")
        let reactDel = channel.postgresChange(DeleteAction.self, schema: "public", table: "message_reactions")
        let memberUpd = channel.postgresChange(UpdateAction.self, schema: "public", table: "members")
        let typing = channel.broadcastStream(event: "typing")
        await channel.subscribe()
        listenTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await change in inserts {
                        if let row = try? change.decodeRecord(as: RealtimeMessageRow.self, decoder: JSONDecoder()) {
                            await self?.append(row)
                        }
                    }
                }
                group.addTask { for await _ in updates { await self?.load() } }
                group.addTask { for await _ in deletes { await self?.load() } }
                group.addTask { for await _ in reactIns { await self?.reloadReactions() } }
                group.addTask { for await _ in reactUpd { await self?.reloadReactions() } }
                group.addTask { for await _ in reactDel { await self?.reloadReactions() } }
                group.addTask { for await _ in memberUpd { await self?.reloadReadTimes() } }
                group.addTask { for await payload in typing { await self?.handleTyping(payload) } }
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
            attachmentPath: row.attachment_path,
            attachmentKind: row.attachment_kind.flatMap(AttachmentKind.init(rawValue:)),
            attachmentName: row.attachment_name,
            attachmentMime: row.attachment_mime,
            replyTo: row.reply_to,
            editedAt: nil,
            createdAt: SupabaseManager.flexibleDate(from: row.created_at) ?? Date(),
            member: sender.map { .init(displayName: $0.displayName, avatar: $0.avatar) }
        )
        messages.append(msg)
    }

    func reloadReactions() async {
        let all = (try? await TriviaService.reactions()) ?? []
        reactionMap = Dictionary(grouping: all, by: { $0.messageId })
    }

    func send(_ text: String, replyTo: UUID? = nil, from member: Member) async {
        let body = text.trimmed
        guard !body.isEmpty else { return }
        do {
            let msg = try await TriviaService.sendMessage(memberId: member.id, body: body, replyTo: replyTo)
            if !messages.contains(where: { $0.id == msg.id }) { messages.append(msg) }
        } catch {
            errorText = "Message failed to send."
        }
    }

    func react(_ message: ChatMessage, emoji: String, from member: Member) async {
        let mine = reactionMap[message.id]?.first { $0.memberId == member.id }
        do {
            if mine?.emoji == emoji {
                try await TriviaService.removeReaction(messageId: message.id, memberId: member.id)
            } else {
                try await TriviaService.setReaction(messageId: message.id, memberId: member.id, emoji: emoji)
            }
            await reloadReactions()
        } catch {
            errorText = "Couldn't react."
        }
    }

    func edit(_ message: ChatMessage, newBody: String) async {
        let trimmed = newBody.trimmed
        guard !trimmed.isEmpty else { return }
        do {
            try await TriviaService.editMessage(id: message.id, newBody: trimmed)
            if let i = messages.firstIndex(where: { $0.id == message.id }) {
                messages[i].body = trimmed
                messages[i].editedAt = Date()
            }
        } catch {
            errorText = "Couldn't edit that message."
        }
    }

    func sendAttachment(_ att: OutgoingAttachment, caption: String, from member: Member) async {
        sending = true
        defer { sending = false }
        do {
            let path = try await TriviaService.uploadChatFile(att.data, memberId: member.id,
                                                              ext: att.ext, contentType: att.mime)
            let msg = try await TriviaService.sendMessage(
                memberId: member.id, body: caption,
                attachmentPath: path, attachmentKind: att.kind,
                attachmentName: att.name, attachmentMime: att.mime)
            if !messages.contains(where: { $0.id == msg.id }) { messages.append(msg) }
        } catch {
            errorText = "Attachment failed to send."
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

// Caches short-lived signed URLs for chat attachments within a session.
@MainActor
final class ChatImageCache {
    static let shared = ChatImageCache()
    private var urls: [String: URL] = [:]
    func url(for path: String) async -> URL? {
        if let u = urls[path] { return u }
        guard let u = try? await TriviaService.signedChatURL(path) else { return nil }
        urls[path] = u
        return u
    }
}

struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var model = ChatModel()
    @State private var draft = ""
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showGifPicker = false
    @State private var showAttachMenu = false
    @State private var fullScreenImage: URL?
    @State private var quickLookURL: URL?
    @State private var reactionTarget: ChatMessage?
    @State private var replyingTo: ChatMessage?
    @State private var editingMessage: ChatMessage?
    @State private var recorder = VoiceRecorder()
    @State private var lastTypingSent = Date.distantPast
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    messageList
                    inputBar
                }
                if let target = reactionTarget {
                    ReactionOverlay(
                        message: target,
                        isMine: target.memberId == app.currentMember?.id,
                        myReaction: model.reactionMap[target.id]?.first { $0.memberId == app.currentMember?.id }?.emoji,
                        onReact: { emoji in
                            if let m = app.currentMember { Task { await model.react(target, emoji: emoji, from: m) } }
                            reactionTarget = nil
                        },
                        onReply: { startReply(target); reactionTarget = nil },
                        onCopy: { UIPasteboard.general.string = target.text; reactionTarget = nil },
                        onEdit: { startEdit(target); reactionTarget = nil },
                        onDelete: { Task { await model.delete(target) }; reactionTarget = nil },
                        onDismiss: { reactionTarget = nil }
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { StencilTitle("Command Center", size: 20) } }
            .task { model.currentMemberId = app.currentMember?.id; await model.start(); await markRead() }
            .onChange(of: draft) { _, v in
                guard !v.trimmed.isEmpty, let m = app.currentMember else { return }
                let now = Date()
                if now.timeIntervalSince(lastTypingSent) > 2 {
                    lastTypingSent = now
                    model.sendTyping(name: m.displayName)
                }
            }
            .onDisappear { model.stop() }
            .confirmationDialog("Add Attachment", isPresented: $showAttachMenu, titleVisibility: .visible) {
                Button("Photo Library") { showPhotoPicker = true }
                if CameraPicker.isAvailable { Button("Camera") { showCamera = true } }
                Button("GIF") { showGifPicker = true }
                Button("Files") { showFiles = true }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showGifPicker) {
                GifPickerView { data in
                    showGifPicker = false
                    Task { await sendGif(data) }
                }
                .flyUpSheet()
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickedItems,
                          maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
            .onChange(of: pickedItems) { _, items in
                guard !items.isEmpty else { return }
                let toSend = items
                pickedItems = []
                Task { for item in toSend { await handlePhotosItem(item) } }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { result in
                    showCamera = false
                    Task { await handleCamera(result) }
                }
                .ignoresSafeArea()
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task { await handleFile(url) }
                }
            }
            .fullScreenCover(item: $fullScreenImage) { url in
                ImageViewer(url: url) { fullScreenImage = nil }
            }
            .quickLookPreview($quickLookURL)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if model.loading {
                        ProgressView().tint(Theme.cyan).padding(.top, 40)
                    } else if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .date(let date):
                            DateSeparator(date: date).padding(.vertical, 8)
                        case .message(let msg, let firstInGroup, let lastInGroup):
                            MessageRow(message: msg,
                                       isMine: msg.memberId == app.currentMember?.id,
                                       firstInGroup: firstInGroup,
                                       lastInGroup: lastInGroup,
                                       repliedMessage: model.messageByID(msg.replyTo),
                                       reactions: model.reactionMap[msg.id] ?? [],
                                       myMemberId: app.currentMember?.id,
                                       seenText: model.seenText(for: msg),
                                       onDelete: { Task { await model.delete(msg) } },
                                       onTapImage: { fullScreenImage = $0 },
                                       onOpenFile: { openFile($0) },
                                       onLongPress: { reactionTarget = msg },
                                       onTapReply: { scrollTo($0, proxy: proxy) })
                            .padding(.top, firstInGroup ? 8 : 0)
                            .id(msg.id)
                        }
                    }
                    if !model.typingMembers.isEmpty {
                        TypingIndicator(names: Array(model.typingMembers.values).sorted())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
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
            .onChange(of: model.typingMembers.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: model.loading) { _, isLoading in
                if !isLoading { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private func scrollTo(_ id: UUID, proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(id, anchor: .center) }
    }

    // Messages interleaved with day separators; each message flagged for grouping.
    private var rows: [ChatRowItem] {
        var result: [ChatRowItem] = []
        var lastDay: String?
        let msgs = model.messages
        for (i, msg) in msgs.enumerated() {
            let day = Self.dayKey(msg.createdAt)
            if day != lastDay { result.append(.date(msg.createdAt)); lastDay = day }
            let prev = i > 0 ? msgs[i - 1] : nil
            let next = i < msgs.count - 1 ? msgs[i + 1] : nil
            let firstInGroup = prev == nil || prev!.memberId != msg.memberId
                || Self.dayKey(prev!.createdAt) != day
                || msg.createdAt.timeIntervalSince(prev!.createdAt) > 300
            let lastInGroup = next == nil || next!.memberId != msg.memberId
                || Self.dayKey(next!.createdAt) != day
                || next!.createdAt.timeIntervalSince(msg.createdAt) > 300
            result.append(.message(msg, firstInGroup: firstInGroup, lastInGroup: lastInGroup))
        }
        return result
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter(); f.timeZone = Config.timeZone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private let bottomAnchor = "chat-bottom"

    private func startReply(_ msg: ChatMessage) {
        editingMessage = nil
        replyingTo = msg
        inputFocused = true
    }

    private func startEdit(_ msg: ChatMessage) {
        replyingTo = nil
        editingMessage = msg
        draft = msg.text
        inputFocused = true
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 34)).foregroundStyle(.black)
            Text("No messages yet. Break the silence, soldier.")
                .font(Theme.label(14)).foregroundStyle(.black)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let reply = replyingTo { composeBanner(icon: "arrowshape.turn.up.left.fill",
                                                      title: "Replying to \(reply.senderName)",
                                                      subtitle: reply.preview) { replyingTo = nil } }
            if editingMessage != nil { composeBanner(icon: "pencil", title: "Editing message",
                                                     subtitle: nil) { cancelEdit() } }
            if recorder.isRecording {
                recordingBar
            } else {
                composeRow
            }
        }
        .background(Theme.surface)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .top)
    }

    private var composeRow: some View {
        HStack(spacing: 10) {
            Button { showAttachMenu = true } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.cyan)
            }
            .disabled(model.sending || editingMessage != nil)

            TextField("", text: $draft, prompt: Text("Message the League…").foregroundColor(.black), axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.surfaceHi)
                .foregroundStyle(Theme.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.line))

            if model.sending {
                ProgressView().frame(width: 32, height: 32)
            } else if editingMessage != nil || !draft.trimmed.isEmpty {
                Button { submit() } label: {
                    Image(systemName: editingMessage != nil ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(draft.trimmed.isEmpty ? .black : Theme.cyan)
                }
                .disabled(draft.trimmed.isEmpty)
            } else {
                Button { Task { await recorder.requestPermissionAndStart() } } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.cyan)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var recordingBar: some View {
        HStack(spacing: 14) {
            Button { recorder.cancel() } label: {
                Image(systemName: "trash").font(.system(size: 22)).foregroundStyle(Theme.red)
            }
            Circle().fill(Theme.red).frame(width: 10, height: 10)
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                Text(timeString(recorder.currentTime))
                    .font(Theme.label(16, weight: .bold)).monospacedDigit().foregroundStyle(.black)
            }
            Text("Recording…").font(Theme.label(13)).foregroundStyle(.black)
            Spacer()
            Button { Task { await sendRecording() } } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundStyle(Theme.cyan)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func timeString(_ t: TimeInterval) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func sendRecording() async {
        guard let data = recorder.stop(), let m = app.currentMember else { recorder.cancel(); return }
        await model.sendAttachment(AttachmentPrep.audio(data), caption: "", from: m)
    }

    private func sendGif(_ data: Data) async {
        guard let m = app.currentMember else { return }
        let caption = draft; draft = ""
        await model.sendAttachment(AttachmentPrep.gif(data), caption: caption, from: m)
    }

    private func composeBanner(icon: String, title: String, subtitle: String?, onCancel: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.cyan).frame(width: 3).clipShape(Capsule())
            Image(systemName: icon).foregroundStyle(Theme.cyan).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.label(12, weight: .bold)).foregroundStyle(.black)
                if let subtitle { Text(subtitle).font(Theme.label(12)).foregroundStyle(.black).lineLimit(1) }
            }
            Spacer()
            Button { onCancel() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.black).font(.system(size: 18))
            }
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private func submit() {
        guard let m = app.currentMember else { return }
        let text = draft; draft = ""
        if let editing = editingMessage {
            editingMessage = nil
            Task { await model.edit(editing, newBody: text) }
        } else {
            let reply = replyingTo?.id
            replyingTo = nil
            Task { await model.send(text, replyTo: reply, from: m) }
        }
    }

    private func cancelEdit() {
        editingMessage = nil
        draft = ""
    }

    // MARK: - Attachment intake

    private func handlePhotosItem(_ item: PhotosPickerItem) async {
        let types = item.supportedContentTypes
        if types.contains(where: { $0.conforms(to: .gif) }) {
            if let data = try? await item.loadTransferable(type: Data.self) {
                await sendAttachment(AttachmentPrep.gif(data))
            }
        } else if types.contains(where: { $0.conforms(to: .movie) }) {
            if let movie = try? await item.loadTransferable(type: MovieFile.self),
               let data = try? Data(contentsOf: movie.url) {
                let ext = movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "video/quicktime"
                await sendAttachment(AttachmentPrep.video(data, ext: ext, mime: mime))
                try? FileManager.default.removeItem(at: movie.url)
            }
        } else if let data = try? await item.loadTransferable(type: Data.self) {
            await sendAttachment(AttachmentPrep.image(fromData: data))
        }
    }

    private func handleCamera(_ result: CameraResult) async {
        switch result {
        case .photo(let image):
            await sendAttachment(AttachmentPrep.image(from: image))
        case .video(let url):
            if let data = try? Data(contentsOf: url) {
                let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "video/quicktime"
                await sendAttachment(AttachmentPrep.video(data, ext: ext, mime: mime))
            }
        case .cancelled:
            break
        }
    }

    private func handleFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        await sendAttachment(AttachmentPrep.file(data, name: url.lastPathComponent, ext: ext, mime: mime))
    }

    private func sendAttachment(_ att: OutgoingAttachment?) async {
        guard let att, let m = app.currentMember else { return }
        let caption = draft; draft = ""
        await model.sendAttachment(att, caption: caption, from: m)
    }

    // Download a file attachment to a temp file and preview it with QuickLook.
    private func openFile(_ message: ChatMessage) {
        guard let path = message.attachmentPath else { return }
        Task {
            guard let url = try? await TriviaService.signedChatURL(path),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            let name = message.attachmentName ?? url.lastPathComponent
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + name)
            try? data.write(to: temp)
            quickLookURL = temp
        }
    }

    private func markRead() async {
        try? await TriviaService.markChatRead()
        app.chatUnread = 0
    }
}

// MARK: - Chat rows

enum ChatRowItem: Identifiable {
    case date(Date)
    case message(ChatMessage, firstInGroup: Bool, lastInGroup: Bool)
    var id: String {
        switch self {
        case .date(let d): return "date-\(d.timeIntervalSince1970)"
        case .message(let m, _, _): return m.id.uuidString
        }
    }
}

struct DateSeparator: View {
    let date: Date
    var body: some View {
        Text(label)
            .font(Theme.label(11, weight: .bold)).tracking(1)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
    }
    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "TODAY" }
        if cal.isDateInYesterday(date) { return "YESTERDAY" }
        let f = DateFormatter(); f.timeZone = Config.timeZone
        f.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "EEEE, MMM d" : "MMM d, yyyy"
        return f.string(from: date).uppercased()
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let isMine: Bool
    let firstInGroup: Bool
    let lastInGroup: Bool
    let repliedMessage: ChatMessage?
    let reactions: [MessageReaction]
    let myMemberId: UUID?
    let seenText: String?
    let onDelete: () -> Void
    let onTapImage: (URL) -> Void
    let onOpenFile: (ChatMessage) -> Void
    let onLongPress: () -> Void
    let onTapReply: (UUID) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine { Spacer(minLength: 40) }
            if !isMine {
                if lastInGroup {
                    LabeledAvatar(avatarId: message.member?.avatar, size: 32, nameSize: 9)
                } else {
                    Color.clear.frame(width: 32)
                }
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine && firstInGroup {
                    Text(message.senderName)
                        .font(Theme.label(12, weight: .bold)).foregroundStyle(.black)
                        .padding(.leading, 4)
                }
                if message.replyTo != nil { replyQuote }
                bubble
                    .overlay(alignment: isMine ? .topLeading : .topTrailing) {
                        if !reactions.isEmpty {
                            ReactionBadges(reactions: reactions, myMemberId: myMemberId)
                                .offset(x: isMine ? -10 : 10, y: -14)
                        }
                    }
                if lastInGroup {
                    Text(timeLabel(message.createdAt) + (message.isEdited ? " · Edited" : ""))
                        .font(Theme.label(10, weight: .regular)).foregroundStyle(.black)
                        .padding(.horizontal, 4)
                }
                if let seenText {
                    Text(seenText)
                        .font(Theme.label(10, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 4)
                }
            }
            if !isMine { Spacer(minLength: 40) }
        }
        .padding(.top, reactions.isEmpty ? 0 : 10)
    }

    @ViewBuilder
    private var bubble: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            if message.hasAttachment {
                AttachmentBubble(message: message, onTapImage: onTapImage, onOpenFile: onOpenFile)
            }
            if message.hasText {
                Text(message.text)
                    .font(Theme.label(16, weight: .regular))
                    .foregroundStyle(isMine ? .black : Theme.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(isMine ? Theme.cyan : Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: isMine ? 0 : 1))
            }
        }
        .onLongPressGesture { onLongPress() }
    }

    @ViewBuilder
    private var replyQuote: some View {
        Button { if let id = message.replyTo { onTapReply(id) } } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 9)).foregroundStyle(.black)
                Text(repliedMessage.map { "\($0.senderName): \($0.preview)" } ?? "Original message")
                    .font(Theme.label(11)).foregroundStyle(.black)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.surfaceHi).clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Theme.line))
        }
        .buttonStyle(.plain)
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = Config.timeZone
        f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "MMM d, h:mm a"
        return f.string(from: date)
    }
}

// Animated "… is typing" bubble.
struct TypingIndicator: View {
    let names: [String]
    @State private var phase = 0

    private var label: String {
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) is typing"
        case 2: return "\(names[0]) & \(names[1]) are typing"
        default: return "Several people are typing"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(.black.opacity(phase == i ? 0.9 : 0.3)).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
            Text(label).font(Theme.label(11)).foregroundStyle(.black)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                phase = (phase + 1) % 3
            }
        }
    }
}

// Tapback badges shown on a bubble corner.
struct ReactionBadges: View {
    let reactions: [MessageReaction]
    let myMemberId: UUID?

    private var grouped: [(emoji: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in reactions { counts[r.emoji, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
    private var mine: Bool { reactions.contains { $0.memberId == myMemberId } }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(grouped.prefix(3), id: \.emoji) { g in
                Text(g.emoji).font(.system(size: 13))
            }
            if reactions.count > 1 {
                Text("\(reactions.count)").font(Theme.label(10, weight: .bold)).foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Theme.surface)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(mine ? Theme.cyan : Theme.line, lineWidth: mine ? 1.5 : 1))
        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
    }
}

// MARK: - Long-press reaction + actions overlay

struct ReactionOverlay: View {
    let message: ChatMessage
    let isMine: Bool
    let myReaction: String?
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    private let tapbacks = ["❤️", "👍", "👎", "😂", "‼️", "❓"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { onDismiss() }
            VStack(spacing: 14) {
                // Reaction bar
                HStack(spacing: 10) {
                    ForEach(tapbacks, id: \.self) { emoji in
                        Button { onReact(emoji) } label: {
                            Text(emoji).font(.system(size: 30))
                                .padding(6)
                                .background(myReaction == emoji ? Theme.cyan.opacity(0.3) : .clear)
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.surface).clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Theme.line))

                // Message preview
                Text(message.preview.isEmpty ? "Attachment" : message.preview)
                    .font(Theme.label(15)).foregroundStyle(isMine ? .black : Theme.textPrimary)
                    .lineLimit(3)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(isMine ? Theme.cyan : Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: 300)

                // Actions
                VStack(spacing: 0) {
                    actionRow("Reply", "arrowshape.turn.up.left", action: onReply)
                    if message.hasText {
                        Divider()
                        actionRow("Copy", "doc.on.doc", action: onCopy)
                    }
                    if isMine && message.hasText {
                        Divider()
                        actionRow("Edit", "pencil", action: onEdit)
                    }
                    if isMine {
                        Divider()
                        actionRow("Delete", "trash", role: .destructive, action: onDelete)
                    }
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                .frame(maxWidth: 260)
            }
            .padding(24)
        }
    }

    private func actionRow(_ title: String, _ icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            HStack {
                Text(title).font(Theme.label(16, weight: .medium))
                Spacer()
                Image(systemName: icon)
            }
            .foregroundStyle(role == .destructive ? Theme.red : .black)
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }
}

// MARK: - Attachment rendering

struct AttachmentBubble: View {
    let message: ChatMessage
    let onTapImage: (URL) -> Void
    let onOpenFile: (ChatMessage) -> Void

    var body: some View {
        if let path = message.attachmentPath {
            switch message.attachmentKind {
            case .image:      ImageAttachment(path: path, onTap: onTapImage)
            case .gif:        GifAttachment(path: path)
            case .video:      VideoAttachment(path: path)
            case .audio:      AudioAttachment(path: path)
            case .file, .none: FileAttachment(message: message, onOpen: onOpenFile)
            }
        }
    }
}

struct ImageAttachment: View {
    let path: String
    let onTap: (URL) -> Void
    @State private var url: URL?

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                            .frame(maxWidth: 240, maxHeight: 300)
                            .onTapGesture { onTap(url) }
                    case .failure: AttachPlaceholder(system: "photo")
                    default: AttachPlaceholder(system: nil)
                    }
                }
            } else { AttachPlaceholder(system: nil) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .task(id: path) { url = await ChatImageCache.shared.url(for: path) }
    }
}

struct GifAttachment: View {
    let path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                GifImageView(image: image)
                    .frame(width: displaySize(image).width, height: displaySize(image).height)
            } else { AttachPlaceholder(system: nil) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .task(id: path) {
            guard let url = await ChatImageCache.shared.url(for: path),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            image = GIF.animatedImage(from: data)
        }
    }

    private func displaySize(_ img: UIImage) -> CGSize {
        let maxW: CGFloat = 240
        let scale = min(1, maxW / max(img.size.width, 1))
        return CGSize(width: img.size.width * scale, height: img.size.height * scale)
    }
}

struct VideoAttachment: View {
    let path: String
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player).frame(width: 240, height: 180)
            } else {
                ZStack {
                    AttachPlaceholder(system: nil)
                    Image(systemName: "play.circle.fill").font(.system(size: 36)).foregroundStyle(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .task(id: path) {
            if let url = await ChatImageCache.shared.url(for: path) { player = AVPlayer(url: url) }
        }
    }
}

struct AudioAttachment: View {
    let path: String
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        HStack(spacing: 10) {
            Button { toggle() } label: {
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(Theme.cyan)
            }
            Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(.black)
            Text("Voice message").font(Theme.label(13, weight: .medium)).foregroundStyle(.black)
        }
        .padding(12).frame(maxWidth: 240, alignment: .leading)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .task(id: path) {
            if let url = await ChatImageCache.shared.url(for: path) { player = AVPlayer(url: url) }
        }
    }

    private func toggle() {
        guard let player else { return }
        if playing {
            player.pause(); playing = false
        } else {
            player.seek(to: .zero); player.play(); playing = true
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { _ in
                playing = false
            }
        }
    }
}

struct FileAttachment: View {
    let message: ChatMessage
    let onOpen: (ChatMessage) -> Void

    var body: some View {
        Button { onOpen(message) } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName).font(.system(size: 26)).foregroundStyle(.black)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.attachmentName ?? "File")
                        .font(Theme.label(15, weight: .bold)).foregroundStyle(.black)
                        .lineLimit(1).truncationMode(.middle)
                    Text(fileTypeLabel)
                        .font(Theme.label(10, weight: .bold)).foregroundStyle(.black)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.down.circle").font(.system(size: 20)).foregroundStyle(Theme.cyan)
            }
            .padding(12)
            .frame(maxWidth: 260, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        }
        .buttonStyle(.plain)
    }

    private var fileTypeLabel: String {
        let ext = (message.attachmentName as NSString?)?.pathExtension ?? ""
        return ext.isEmpty ? "FILE" : ext.uppercased()
    }

    private var iconName: String {
        let mime = message.attachmentMime ?? ""
        if mime.contains("pdf") { return "doc.richtext.fill" }
        if mime.hasPrefix("audio/") { return "waveform" }
        if mime.hasPrefix("text/") { return "doc.text.fill" }
        if mime.contains("zip") || mime.contains("compressed") { return "doc.zipper" }
        return "doc.fill"
    }
}

struct AttachPlaceholder: View {
    let system: String?
    var body: some View {
        ZStack {
            Theme.surfaceHi
            if let system { Image(systemName: system).font(.title).foregroundStyle(.black) }
            else { ProgressView() }
        }
        .frame(width: 200, height: 150)
    }
}

// UIImageView animates an animated UIImage automatically.
struct GifImageView: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.image = image
        return v
    }
    func updateUIView(_ uiView: UIImageView, context: Context) { uiView.image = image }
}

// Full-screen image viewer.
struct ImageViewer: View {
    let url: URL
    let onClose: () -> Void
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFit() }
                else { ProgressView().tint(.white) }
            }
            VStack {
                HStack {
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 30)).foregroundStyle(.white).padding()
                    }
                }
                Spacer()
            }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

// MARK: - Outgoing attachment prep

struct OutgoingAttachment {
    let data: Data
    let kind: AttachmentKind
    let ext: String
    let mime: String
    let name: String?
}

enum AttachmentPrep {
    static func image(fromData data: Data) -> OutgoingAttachment? {
        guard let jpeg = ImagePrep.jpeg(fromData: data) else { return nil }
        return OutgoingAttachment(data: jpeg, kind: .image, ext: "jpg", mime: "image/jpeg", name: nil)
    }
    static func image(from image: UIImage) -> OutgoingAttachment? {
        guard let jpeg = ImagePrep.jpeg(from: image) else { return nil }
        return OutgoingAttachment(data: jpeg, kind: .image, ext: "jpg", mime: "image/jpeg", name: nil)
    }
    static func gif(_ data: Data) -> OutgoingAttachment {
        OutgoingAttachment(data: data, kind: .gif, ext: "gif", mime: "image/gif", name: nil)
    }
    static func video(_ data: Data, ext: String, mime: String) -> OutgoingAttachment {
        OutgoingAttachment(data: data, kind: .video, ext: ext, mime: mime, name: nil)
    }
    static func audio(_ data: Data) -> OutgoingAttachment {
        OutgoingAttachment(data: data, kind: .audio, ext: "m4a", mime: "audio/m4a", name: nil)
    }
    // Files that are really media still render inline.
    static func file(_ data: Data, name: String, ext: String, mime: String) -> OutgoingAttachment {
        let kind: AttachmentKind
        if mime == "image/gif" { kind = .gif }
        else if mime.hasPrefix("image/") { kind = .image }
        else if mime.hasPrefix("video/") { kind = .video }
        else { kind = .file }
        let safeExt = ext.isEmpty ? "bin" : ext
        return OutgoingAttachment(data: data, kind: kind, ext: safeExt, mime: mime,
                                  name: kind == .file ? name : nil)
    }
}

enum ImagePrep {
    static func jpeg(fromData data: Data, maxDim: CGFloat = 1600, quality: CGFloat = 0.7) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpeg(from: image, maxDim: maxDim, quality: quality)
    }
    static func jpeg(from image: UIImage, maxDim: CGFloat = 1600, quality: CGFloat = 0.7) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDim / max(size.width, size.height))
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return scaled.jpegData(compressionQuality: quality)
    }
}

// Decodes GIF data into an animated UIImage.
enum GIF {
    static func animatedImage(from data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var duration = 0.0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            duration += delay(src, i)
        }
        if duration <= 0 { duration = Double(count) * 0.1 }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    private static func delay(_ src: CGImageSource, _ i: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return d < 0.02 ? 0.1 : d
    }
}

// MARK: - UIKit pickers

enum CameraResult { case photo(UIImage); case video(URL); case cancelled }

struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    let onResult: (CameraResult) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onResult: (CameraResult) -> Void
        init(onResult: @escaping (CameraResult) -> Void) { self.onResult = onResult }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL { onResult(.video(url)) }
            else if let image = info[.originalImage] as? UIImage { onResult(.photo(image)) }
            else { onResult(.cancelled) }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onResult(.cancelled) }
    }
}

// MARK: - Giphy GIF search

struct GiphyItem: Identifiable, Decodable {
    let id: String
    let images: Images
    struct Images: Decodable {
        let fixed_width: GImage
        let downsized: GImage?
    }
    struct GImage: Decodable { let url: String }

    var previewURL: URL? { URL(string: images.fixed_width.url) }
    var sendURL: URL? { URL(string: (images.downsized ?? images.fixed_width).url) }
}

enum GiphyService {
    private struct Response: Decodable { let data: [GiphyItem] }

    static func trending() async -> [GiphyItem] {
        await fetch("https://api.giphy.com/v1/gifs/trending?api_key=\(Config.giphyKey)&limit=24&rating=pg-13")
    }
    static func search(_ query: String) async -> [GiphyItem] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return await fetch("https://api.giphy.com/v1/gifs/search?api_key=\(Config.giphyKey)&q=\(q)&limit=24&rating=pg-13")
    }
    private static func fetch(_ urlString: String) async -> [GiphyItem] {
        guard let url = URL(string: urlString),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let resp = try? JSONDecoder().decode(Response.self, from: data) else { return [] }
        return resp.data
    }
}

struct GifPickerView: View {
    let onPick: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var gifs: [GiphyItem] = []
    @State private var loading = false
    @State private var downloadingId: String?
    @State private var searchTask: Task<Void, Never>?

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.black)
                        TextField("", text: $query, prompt: Text("Search GIFs").foregroundColor(.black))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.surfaceHi).clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line))
                    .padding(.horizontal, 16).padding(.top, 8)

                    ScrollView {
                        if !Config.giphyConfigured {
                            gifKeyHint
                        } else if loading {
                            ProgressView().tint(Theme.cyan).padding(.top, 40)
                        } else if gifs.isEmpty {
                            Text(query.trimmed.isEmpty ? "Search for a GIF." : "No GIFs found.")
                                .font(Theme.label(14)).foregroundStyle(.black).padding(.top, 40)
                        } else {
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(gifs) { gif in
                                    Button { pick(gif) } label: {
                                        RemoteGif(url: gif.previewURL)
                                            .frame(height: 110)
                                            .frame(maxWidth: .infinity)
                                            .clipped()
                                            .overlay { if downloadingId == gif.id { Color.black.opacity(0.4); ProgressView().tint(.white) } }
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    .disabled(downloadingId != nil)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        Text("Powered by GIPHY").font(Theme.label(10)).foregroundStyle(.black).padding(.top, 8)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { StencilTitle("GIFs", size: 20) }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() }.foregroundStyle(.black) }
            }
            .task { loading = true; gifs = await GiphyService.trending(); loading = false }
            .onChange(of: query) { _, q in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    loading = true
                    gifs = q.trimmed.isEmpty ? await GiphyService.trending() : await GiphyService.search(q.trimmed)
                    loading = false
                }
            }
        }
    }

    private var gifKeyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars").font(.system(size: 34)).foregroundStyle(Theme.cyan)
            Text("GIF search needs a free Giphy key")
                .font(Theme.label(15, weight: .bold)).foregroundStyle(.black)
            Text("Add one at developers.giphy.com, then paste it into Config.swift (giphyKey). Until then, send GIFs from Photo Library or Files.")
                .font(Theme.label(13)).foregroundStyle(.black)
                .multilineTextAlignment(.center)
        }
        .padding(30)
    }

    private func pick(_ gif: GiphyItem) {
        guard Config.giphyConfigured, let url = gif.sendURL else { return }
        downloadingId = gif.id
        Task {
            defer { downloadingId = nil }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            onPick(data)
        }
    }
}

// A remote GIF that downloads and animates in place.
struct RemoteGif: View {
    let url: URL?
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Theme.surfaceHi
            if let image { GifImageView(image: image) }
            else { ProgressView().tint(Theme.cyan) }
        }
        .task(id: url) {
            guard let url, let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            image = GIF.animatedImage(from: data)
        }
    }
}

// Lets PhotosPicker deliver a video as a temp file URL.
struct MovieFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + ext)
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: received.file, to: temp)
            return MovieFile(url: temp)
        }
    }
}

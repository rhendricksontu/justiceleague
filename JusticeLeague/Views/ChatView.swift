import SwiftUI
import Supabase
import PhotosUI
import UIKit

@MainActor
@Observable
final class ChatModel {
    var messages: [ChatMessage] = []
    var loading = true
    var sending = false
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
            imagePath: row.image_path,
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

    func sendImage(_ data: Data, caption: String, from member: Member) async {
        sending = true
        defer { sending = false }
        do {
            let path = try await TriviaService.uploadChatImage(data, memberId: member.id)
            let msg = try await TriviaService.sendMessage(memberId: member.id, body: caption, imagePath: path)
            if !messages.contains(where: { $0.id == msg.id }) { messages.append(msg) }
        } catch {
            errorText = "Photo failed to send."
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

// Caches short-lived signed URLs for chat images within a session.
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
    @State private var pickedItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showAttachMenu = false
    @State private var fullScreenImage: URL?
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
            .toolbar { ToolbarItem(placement: .principal) { StencilTitle("Command Center", size: 20) } }
            .task {
                await model.start()
                await markRead()
            }
            .onDisappear { model.stop() }
            .confirmationDialog("Add a Photo", isPresented: $showAttachMenu, titleVisibility: .visible) {
                Button("Photo Library") { showPhotoPicker = true }
                if CameraPicker.isAvailable { Button("Take Photo") { showCamera = true } }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickedItem, matching: .images)
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let jpeg = ImagePrep.jpeg(fromData: data) {
                        await sendImage(jpeg)
                    }
                    pickedItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    if let image, let jpeg = ImagePrep.jpeg(from: image) {
                        Task { await sendImage(jpeg) }
                    }
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $fullScreenImage) { url in
                ImageViewer(url: url) { fullScreenImage = nil }
            }
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
                        MessageRow(message: msg,
                                   isMine: msg.memberId == app.currentMember?.id,
                                   onDelete: { Task { await model.delete(msg) } },
                                   onTapImage: { fullScreenImage = $0 })
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
                .font(.system(size: 34)).foregroundStyle(.black)
            Text("No messages yet. Break the silence, soldier.")
                .font(Theme.label(14)).foregroundStyle(.black)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Button { showAttachMenu = true } label: {
                Image(systemName: "camera.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.cyan)
            }
            .disabled(model.sending)

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
            } else {
                Button {
                    guard let m = app.currentMember else { return }
                    let text = draft
                    draft = ""
                    Task { await model.send(text, from: m) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(draft.trimmed.isEmpty ? .black : Theme.cyan)
                }
                .disabled(draft.trimmed.isEmpty)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.line), alignment: .top)
    }

    private func sendImage(_ data: Data) async {
        guard let m = app.currentMember else { return }
        let caption = draft
        draft = ""
        await model.sendImage(data, caption: caption, from: m)
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
    let onTapImage: (URL) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine { Spacer(minLength: 40) }
            if !isMine {
                LabeledAvatar(avatarId: message.member?.avatar, size: 32, nameSize: 9)
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine {
                    Text(message.senderName)
                        .font(Theme.label(12, weight: .bold))
                        .foregroundStyle(.black)
                }
                if let path = message.imagePath {
                    ChatAttachment(path: path, onTap: onTapImage)
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
                Text(timeLabel(message.createdAt))
                    .font(Theme.label(10, weight: .regular))
                    .foregroundStyle(.black)
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

// An inline chat image, loaded from a signed URL; tap to view full screen.
struct ChatAttachment: View {
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
                    case .failure:
                        placeholder(system: "photo")
                    default:
                        placeholder(system: nil)
                    }
                }
            } else {
                placeholder(system: nil)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .task(id: path) { url = await ChatImageCache.shared.url(for: path) }
    }

    private func placeholder(system: String?) -> some View {
        ZStack {
            Theme.surfaceHi
            if let system { Image(systemName: system).font(.title).foregroundStyle(.black) }
            else { ProgressView() }
        }
        .frame(width: 200, height: 150)
    }
}

// Full-screen zoomable image viewer.
struct ImageViewer: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                            .padding()
                    }
                }
                Spacer()
            }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

// JPEG downscale/compress helpers for uploads.
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

// UIKit camera wrapper (camera is unavailable on the simulator).
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    let onImage: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage?) -> Void
        init(onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onImage(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onImage(nil)
        }
    }
}

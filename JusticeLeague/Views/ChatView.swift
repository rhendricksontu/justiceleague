import SwiftUI
import Supabase
import PhotosUI
import UIKit
import AVKit
import ImageIO
import UniformTypeIdentifiers
import QuickLook

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
            attachmentPath: row.attachment_path,
            attachmentKind: row.attachment_kind.flatMap(AttachmentKind.init(rawValue:)),
            attachmentName: row.attachment_name,
            attachmentMime: row.attachment_mime,
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
    @State private var pickedItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showAttachMenu = false
    @State private var fullScreenImage: URL?
    @State private var quickLookURL: URL?
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
            .task { await model.start(); await markRead() }
            .onDisappear { model.stop() }
            .confirmationDialog("Add Attachment", isPresented: $showAttachMenu, titleVisibility: .visible) {
                Button("Photo Library") { showPhotoPicker = true }
                if CameraPicker.isAvailable { Button("Camera") { showCamera = true } }
                Button("Files") { showFiles = true }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $pickedItem,
                          matching: .any(of: [.images, .videos]))
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task { await handlePhotosItem(item); pickedItem = nil }
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
                                   onTapImage: { fullScreenImage = $0 },
                                   onOpenFile: { openFile($0) })
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
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 28))
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
                    let text = draft; draft = ""
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

// MARK: - Message row

struct MessageRow: View {
    let message: ChatMessage
    let isMine: Bool
    let onDelete: () -> Void
    let onTapImage: (URL) -> Void
    let onOpenFile: (ChatMessage) -> Void

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

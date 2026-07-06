import Foundation
import Supabase

// All trivia + roster data access. RLS on the server is the real gatekeeper;
// these are just typed helpers over Postgrest.
enum TriviaService {
    private static var db: SupabaseClient { SupabaseManager.client }

    // MARK: Questions

    static func question(on day: String) async throws -> TriviaQuestion? {
        let rows: [TriviaQuestion] = try await db
            .from("trivia_questions")
            .select()
            .eq("question_date", value: day)
            .limit(1)
            .execute().value
        return rows.first
    }

    static func todaysQuestion() async throws -> TriviaQuestion? {
        try await question(on: Date.triviaDayString())
    }

    struct NewQuestion: Encodable {
        let question_date: String
        let prompt: String
        let created_by: UUID
    }
    struct NewAnswerKey: Encodable {
        let question_id: UUID
        let correct_answer: String
    }

    // Master creates today's question + its (hidden) answer key.
    @discardableResult
    static func createQuestion(prompt: String, answer: String, by memberId: UUID) async throws -> TriviaQuestion {
        let day = Date.triviaDayString()
        let inserted: TriviaQuestion = try await db
            .from("trivia_questions")
            .insert(NewQuestion(question_date: day, prompt: prompt, created_by: memberId))
            .select()
            .single()
            .execute().value

        try await db
            .from("trivia_answer_keys")
            .insert(NewAnswerKey(question_id: inserted.id, correct_answer: answer))
            .execute()

        return inserted
    }

    struct RevealPatch: Encodable { let revealed = true; let revealed_at: String }

    static func reveal(question: TriviaQuestion) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await db
            .from("trivia_questions")
            .update(RevealPatch(revealed_at: now))
            .eq("id", value: question.id)
            .execute()
    }

    // MARK: Answer key (visible to master anytime, everyone after reveal)

    static func answerKey(for questionId: UUID) async throws -> AnswerKey? {
        let rows: [AnswerKey] = try await db
            .from("trivia_answer_keys")
            .select()
            .eq("question_id", value: questionId)
            .limit(1)
            .execute().value
        return rows.first
    }

    // MARK: Responses

    static func myResponse(questionId: UUID, memberId: UUID) async throws -> TriviaResponse? {
        let rows: [TriviaResponse] = try await db
            .from("trivia_responses")
            .select()
            .eq("question_id", value: questionId)
            .eq("member_id", value: memberId)
            .limit(1)
            .execute().value
        return rows.first
    }

    struct NewResponse: Encodable {
        let question_id: UUID
        let member_id: UUID
        let answer: String
    }

    static func submit(questionId: UUID, memberId: UUID, answer: String) async throws {
        try await db
            .from("trivia_responses")
            .upsert(
                NewResponse(question_id: questionId, member_id: memberId, answer: answer),
                onConflict: "question_id,member_id"
            )
            .execute()
    }

    // Responses joined with names. Before reveal RLS returns only your own row;
    // after reveal it returns everyone's.
    static func responses(questionId: UUID) async throws -> [ResponseWithName] {
        try await db
            .from("trivia_responses")
            .select("id, question_id, member_id, answer, is_correct, submitted_at, member:members(display_name)")
            .eq("question_id", value: questionId)
            .order("submitted_at", ascending: true)
            .execute().value
    }

    struct GradePatch: Encodable { let is_correct: Bool; let graded_at: String }

    static func grade(responseId: UUID, correct: Bool) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await db
            .from("trivia_responses")
            .update(GradePatch(is_correct: correct, graded_at: now))
            .eq("id", value: responseId)
            .execute()
    }

    // Who has answered (names only, no answers) — safe to show before reveal.
    static func participation(questionId: UUID) async throws -> [Participation] {
        try await db
            .rpc("question_participation", params: ["qid": questionId])
            .execute().value
    }

    // MARK: Leaderboards

    static func monthlyScores(monthStart: String) async throws -> [MonthlyScore] {
        try await db
            .from("v_monthly_scores")
            .select()
            .eq("month", value: monthStart)
            .order("correct_count", ascending: false)
            .execute().value
    }

    static func monthlyWinners() async throws -> [MonthlyWinner] {
        try await db
            .from("v_monthly_winners")
            .select()
            .order("month", ascending: false)
            .execute().value
    }

    // MARK: Members (admin)

    static func allMembers() async throws -> [Member] {
        try await db
            .from("members")
            .select()
            .order("display_name", ascending: true)
            .execute().value
    }

    struct NewMember: Encodable {
        let phone: String
        let display_name: String
        let is_admin: Bool
        let is_trivia_master: Bool
        let is_active: Bool
    }

    static func addMember(phone: String, name: String, admin: Bool, master: Bool) async throws {
        try await db.from("members").insert(
            NewMember(phone: phone, display_name: name, is_admin: admin,
                      is_trivia_master: master, is_active: true)
        ).execute()
    }

    struct MemberPatch: Encodable {
        let phone: String
        let display_name: String
        let is_admin: Bool
        let is_trivia_master: Bool
        let is_active: Bool
    }

    static func updateMember(_ m: Member) async throws {
        try await db.from("members").update(
            MemberPatch(phone: m.phone, display_name: m.displayName, is_admin: m.isAdmin,
                        is_trivia_master: m.isTriviaMaster, is_active: m.isActive)
        ).eq("id", value: m.id).execute()
    }

    static func deleteMember(id: UUID) async throws {
        try await db.from("members").delete().eq("id", value: id).execute()
    }

    // A member updating their own name + phone (via the security-definer RPC).
    static func updateMyProfile(name: String, phone: String) async throws {
        try await db.rpc("update_my_profile",
                         params: ["new_name": name, "new_phone": phone]).execute()
    }

    struct AvatarParam: Encodable { let new_avatar: String? }
    static func setMyAvatar(_ id: String?) async throws {
        try await db.rpc("set_my_avatar", params: AvatarParam(new_avatar: id)).execute()
    }

    // MARK: Group chat

    static let chatSelect = "id, member_id, body, attachment_path, attachment_kind, attachment_name, attachment_mime, reply_to, edited_at, created_at, member:members!messages_member_id_fkey(display_name, avatar)"

    // Most recent messages (joined with sender name + avatar), oldest-first for display.
    static func messages(limit: Int = 200) async throws -> [ChatMessage] {
        let rows: [ChatMessage] = try await db
            .from("messages")
            .select(chatSelect)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute().value
        return rows.reversed()
    }

    struct NewChatMessage: Encodable {
        let member_id: UUID
        let body: String?
        let attachment_path: String?
        let attachment_kind: String?
        let attachment_name: String?
        let attachment_mime: String?
        let reply_to: String?
    }

    @discardableResult
    static func sendMessage(memberId: UUID, body: String?,
                            attachmentPath: String? = nil, attachmentKind: AttachmentKind? = nil,
                            attachmentName: String? = nil, attachmentMime: String? = nil,
                            replyTo: UUID? = nil) async throws -> ChatMessage {
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await db
            .from("messages")
            .insert(NewChatMessage(member_id: memberId,
                                   body: (trimmed?.isEmpty ?? true) ? nil : trimmed,
                                   attachment_path: attachmentPath,
                                   attachment_kind: attachmentKind?.rawValue,
                                   attachment_name: attachmentName,
                                   attachment_mime: attachmentMime,
                                   reply_to: replyTo?.uuidString))
            .select(chatSelect)
            .single()
            .execute().value
    }

    struct EditPatch: Encodable { let body: String; let edited_at: String }

    static func editMessage(id: UUID, newBody: String) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.from("messages")
            .update(EditPatch(body: newBody, edited_at: now))
            .eq("id", value: id)
            .execute()
    }

    // MARK: Reactions (tapbacks)

    static func reactions() async throws -> [MessageReaction] {
        try await db.from("message_reactions").select().execute().value
    }

    struct NewReaction: Encodable { let message_id: UUID; let member_id: UUID; let emoji: String }

    static func setReaction(messageId: UUID, memberId: UUID, emoji: String) async throws {
        try await db.from("message_reactions")
            .upsert(NewReaction(message_id: messageId, member_id: memberId, emoji: emoji),
                    onConflict: "message_id,member_id")
            .execute()
    }

    static func removeReaction(messageId: UUID, memberId: UUID) async throws {
        try await db.from("message_reactions")
            .delete()
            .eq("message_id", value: messageId)
            .eq("member_id", value: memberId)
            .execute()
    }

    // Upload arbitrary data to the private chat-media bucket, returning its storage path.
    static func uploadChatFile(_ data: Data, memberId: UUID, ext: String, contentType: String) async throws -> String {
        let safeExt = ext.isEmpty ? "bin" : ext
        let path = "\(memberId.uuidString.lowercased())/\(UUID().uuidString).\(safeExt)"
        try await db.storage.from("chat-media")
            .upload(path, data: data, options: FileOptions(contentType: contentType))
        return path
    }

    // A short-lived signed URL for displaying/downloading a chat attachment.
    static func signedChatURL(_ path: String) async throws -> URL {
        try await db.storage.from("chat-media").createSignedURL(path: path, expiresIn: 3600)
    }

    static func deleteMessage(id: UUID) async throws {
        try await db.from("messages").delete().eq("id", value: id).execute()
    }

    static func markChatRead() async throws {
        try await db.rpc("mark_chat_read").execute()
    }

    static func chatUnreadCount() async throws -> Int {
        try await db.rpc("chat_unread_count").execute().value
    }

    // MARK: Push tokens

    struct DeviceTokenParam: Encodable { let p_token: String; let p_platform: String }
    static func registerDeviceToken(_ token: String, platform: String = "ios") async throws {
        try await db.rpc("register_device_token",
                         params: DeviceTokenParam(p_token: token, p_platform: platform)).execute()
    }
}

// Formatting helpers used by the leaderboard views.
enum MonthFmt {
    static func startOfCurrentMonth() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Config.timeZone
        let comps = cal.dateComponents([.year, .month], from: Date())
        let start = cal.date(from: comps)!
        return SupabaseManager.dayFormatter.string(from: start)
    }

    static func label(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "LLLL yyyy"
        return f.string(from: date)
    }
}

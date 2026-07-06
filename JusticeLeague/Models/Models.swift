import Foundation

struct Member: Codable, Identifiable, Hashable {
    let id: UUID
    var phone: String
    var displayName: String
    var isAdmin: Bool
    var isTriviaMaster: Bool
    var isActive: Bool
    var avatar: String?

    enum CodingKeys: String, CodingKey {
        case id, phone, avatar
        case displayName = "display_name"
        case isAdmin = "is_admin"
        case isTriviaMaster = "is_trivia_master"
        case isActive = "is_active"
    }
}

struct TriviaQuestion: Codable, Identifiable, Hashable {
    let id: UUID
    var questionDate: Date
    var prompt: String
    var createdBy: UUID
    var revealed: Bool
    var revealedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, prompt, revealed
        case questionDate = "question_date"
        case createdBy = "created_by"
        case revealedAt = "revealed_at"
    }
}

struct AnswerKey: Codable {
    let questionId: UUID
    let correctAnswer: String
    enum CodingKeys: String, CodingKey {
        case questionId = "question_id"
        case correctAnswer = "correct_answer"
    }
}

struct TriviaResponse: Codable, Identifiable, Hashable {
    let id: UUID
    let questionId: UUID
    let memberId: UUID
    var answer: String
    var isCorrect: Bool?
    var submittedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, answer
        case questionId = "question_id"
        case memberId = "member_id"
        case isCorrect = "is_correct"
        case submittedAt = "submitted_at"
    }
}

// A response joined with the responder's display name (for the reveal + grading list).
struct ResponseWithName: Codable, Identifiable, Hashable {
    let id: UUID
    let questionId: UUID
    let memberId: UUID
    var answer: String
    var isCorrect: Bool?
    var submittedAt: Date
    var member: MemberName?

    struct MemberName: Codable, Hashable {
        let displayName: String
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }

    var name: String { member?.displayName ?? "Unknown" }

    enum CodingKeys: String, CodingKey {
        case id, answer, member
        case questionId = "question_id"
        case memberId = "member_id"
        case isCorrect = "is_correct"
        case submittedAt = "submitted_at"
    }
}

struct Participation: Codable, Identifiable, Hashable {
    let memberId: UUID
    let displayName: String
    let hasAnswered: Bool
    var id: UUID { memberId }

    enum CodingKeys: String, CodingKey {
        case memberId = "member_id"
        case displayName = "display_name"
        case hasAnswered = "has_answered"
    }
}

// A group-chat message, joined with the sender's name + avatar.
enum AttachmentKind: String, Codable, Hashable {
    case image, gif, video, audio, file
}

struct ChatMessage: Codable, Identifiable, Hashable {
    let id: UUID
    let memberId: UUID
    var body: String?
    var attachmentPath: String?
    var attachmentKind: AttachmentKind?
    var attachmentName: String?
    var attachmentMime: String?
    var replyTo: UUID?
    var editedAt: Date?
    var createdAt: Date
    var member: Sender?

    struct Sender: Codable, Hashable {
        let displayName: String
        let avatar: String?
        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case avatar
        }
    }

    var senderName: String { member?.displayName ?? "Unknown" }
    var text: String { body ?? "" }
    var hasText: Bool { !(body ?? "").isEmpty }
    var hasAttachment: Bool { attachmentPath != nil }
    var isEdited: Bool { editedAt != nil }

    // One-line summary for reply previews / notifications.
    var preview: String {
        if hasText { return text }
        switch attachmentKind {
        case .image: return "📷 Photo"
        case .gif:   return "🎬 GIF"
        case .video: return "🎬 Video"
        case .audio: return "🎤 Voice message"
        case .file:  return "📎 \(attachmentName ?? "File")"
        case .none:  return ""
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, body, member
        case memberId = "member_id"
        case attachmentPath = "attachment_path"
        case attachmentKind = "attachment_kind"
        case attachmentName = "attachment_name"
        case attachmentMime = "attachment_mime"
        case replyTo = "reply_to"
        case editedAt = "edited_at"
        case createdAt = "created_at"
    }
}

// Raw shape of a realtime INSERT payload (no joined sender columns).
struct RealtimeMessageRow: Decodable {
    let id: UUID
    let member_id: UUID
    let body: String?
    let attachment_path: String?
    let attachment_kind: String?
    let attachment_name: String?
    let attachment_mime: String?
    let reply_to: UUID?
    let created_at: String
}

enum Recurrence: String, Codable, CaseIterable, Hashable {
    case none, daily, weekly, biweekly, monthly
    var label: String {
        switch self {
        case .none: return "Does not repeat"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        case .biweekly: return "Every 2 weeks"
        case .monthly: return "Every month"
        }
    }
    var shortLabel: String {
        switch self {
        case .none: return ""
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .biweekly: return "Biweekly"
        case .monthly: return "Monthly"
        }
    }
}

struct CalEvent: Codable, Identifiable, Hashable {
    let id: UUID
    var createdBy: UUID?
    var title: String
    var description: String?
    var startsAt: Date
    var endsAt: Date
    var recurrence: Recurrence
    var recurrenceUntil: Date?
    var creator: Creator?

    struct Creator: Codable, Hashable {
        let displayName: String
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }
    var creatorName: String { creator?.displayName ?? "Someone" }

    enum CodingKeys: String, CodingKey {
        case id, title, description, recurrence, creator
        case createdBy = "created_by"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case recurrenceUntil = "recurrence_until"
    }
}

enum RSVPStatus: String, Codable, CaseIterable, Hashable {
    case yes, no, maybe
    var label: String { rawValue.capitalized }
}

struct EventRSVP: Codable, Hashable {
    let eventId: UUID
    let memberId: UUID
    var occurrence: String   // "yyyy-MM-dd"
    var status: RSVPStatus
    var member: NameOnly?

    struct NameOnly: Codable, Hashable {
        let displayName: String
        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
    }

    enum CodingKeys: String, CodingKey {
        case status, occurrence, member
        case eventId = "event_id"
        case memberId = "member_id"
    }
}

struct MessageReaction: Codable, Identifiable, Hashable {
    let messageId: UUID
    let memberId: UUID
    var emoji: String
    var id: String { "\(messageId)-\(memberId)" }
    enum CodingKeys: String, CodingKey {
        case emoji
        case messageId = "message_id"
        case memberId = "member_id"
    }
}

struct MonthlyScore: Codable, Identifiable, Hashable {
    let memberId: UUID
    let displayName: String
    let month: Date
    let correctCount: Int
    var id: UUID { memberId }

    enum CodingKeys: String, CodingKey {
        case month
        case memberId = "member_id"
        case displayName = "display_name"
        case correctCount = "correct_count"
    }
}

struct MonthlyWinner: Codable, Identifiable, Hashable {
    let month: Date
    let memberId: UUID
    let displayName: String
    let correctCount: Int
    var id: String { "\(month.timeIntervalSince1970)-\(memberId)" }

    enum CodingKeys: String, CodingKey {
        case month
        case memberId = "member_id"
        case displayName = "display_name"
        case correctCount = "correct_count"
    }
}

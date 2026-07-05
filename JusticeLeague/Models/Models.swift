import Foundation

struct Member: Codable, Identifiable, Hashable {
    let id: UUID
    var phone: String
    var displayName: String
    var isAdmin: Bool
    var isTriviaMaster: Bool
    var isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, phone
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

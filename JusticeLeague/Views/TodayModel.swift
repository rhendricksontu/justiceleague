import Foundation
import Observation

@MainActor
@Observable
final class TodayModel {
    var loading = true
    var errorText: String?
    var day: String = Date.triviaDayString()   // the day being viewed (yyyy-MM-dd)

    var question: TriviaQuestion?
    var myResponse: TriviaResponse?
    var answerKey: AnswerKey?
    var responses: [ResponseWithName] = []
    var participation: [Participation] = []

    var answeredCount: Int { participation.filter(\.hasAnswered).count }
    var totalCount: Int { participation.count }

    func load(member: Member) async {
        loading = true
        errorText = nil
        do {
            let q = try await TriviaService.question(on: day)
            question = q
            myResponse = nil
            responses = []
            participation = []
            answerKey = nil
            guard let q else { loading = false; return }

            // Everyone can see who has answered.
            participation = (try? await TriviaService.participation(questionId: q.id)) ?? []

            // Master sees the answer key anytime; members only after reveal.
            answerKey = try? await TriviaService.answerKey(for: q.id)

            if member.isTriviaMaster {
                if q.revealed {
                    responses = try await TriviaService.responses(questionId: q.id)
                }
            } else {
                myResponse = try await TriviaService.myResponse(questionId: q.id, memberId: member.id)
                if q.revealed {
                    responses = try await TriviaService.responses(questionId: q.id)
                }
            }
        } catch {
            errorText = friendly(error)
        }
        loading = false
    }

    func post(prompt: String, answer: String, by member: Member) async -> Bool {
        errorText = nil
        do {
            _ = try await TriviaService.createQuestion(prompt: prompt, answer: answer, by: member.id, day: day)
            await load(member: member)
            return true
        } catch {
            errorText = friendly(error)
            return false
        }
    }

    func submit(answer: String, member: Member) async -> Bool {
        guard let q = question else { return false }
        errorText = nil
        do {
            try await TriviaService.submit(questionId: q.id, memberId: member.id, answer: answer)
            await load(member: member)
            return true
        } catch {
            errorText = friendly(error)
            return false
        }
    }

    func reveal(member: Member) async {
        guard let q = question else { return }
        errorText = nil
        do {
            try await TriviaService.reveal(question: q)
            await load(member: member)
        } catch {
            errorText = friendly(error)
        }
    }

    func grade(_ response: ResponseWithName, correct: Bool, member: Member) async {
        do {
            try await TriviaService.grade(responseId: response.id, correct: correct)
            responses = try await TriviaService.responses(questionId: response.questionId)
        } catch {
            errorText = friendly(error)
        }
    }

    private func friendly(_ error: Error) -> String {
        "Couldn't reach HQ. Pull to refresh and try again."
    }
}

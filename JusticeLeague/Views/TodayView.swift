import SwiftUI

struct TodayView: View {
    @Environment(AppState.self) private var app
    @State private var model = TodayModel()
    @State private var lbModel = LeaderboardModel()

    private var member: Member? { app.currentMember }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header

                        if model.loading {
                            ProgressView().tint(Theme.cyan).frame(maxWidth: .infinity).padding(.top, 40)
                        } else if let m = member {
                            content(for: m)
                        }

                        if let err = model.errorText {
                            Text(err).font(Theme.label(13)).foregroundStyle(Theme.red)
                        }

                        Divider().overlay(Theme.line).padding(.vertical, 4)
                        LeaderboardSection(model: lbModel)
                    }
                    .padding(20)
                }
                .refreshable { await refreshAll() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { StencilTitle("Daily Intel", size: 20) } }
            .task { await refreshAll() }
        }
    }

    private func refreshAll() async {
        if let m = member { await model.load(member: m) }
        await lbModel.load()
    }

    private var header: some View {
        Text(todayLabel().uppercased())
            .font(Theme.label(13, weight: .bold))
            .tracking(2)
            .foregroundStyle(.black)
    }

    @ViewBuilder
    private func content(for m: Member) -> some View {
        if let q = model.question {
            // Question prompt panel — shown to everyone.
            FieldPanel {
                VStack(alignment: .leading, spacing: 10) {
                    StencilTitle("MISSION BRIEFING", size: 15, solid: true)
                    Text(q.prompt)
                        .font(Theme.label(19, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if q.revealed, let key = model.answerKey {
                        Divider().overlay(Theme.oliveDrab)
                        Label("Answer: \(key.correctAnswer)", systemImage: "checkmark.seal.fill")
                            .font(Theme.label(16, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
            }

            if m.isTriviaMaster {
                masterSection(q: q, m: m)
            } else {
                memberSection(q: q, m: m)
            }
        } else {
            noQuestionSection(for: m)
        }
    }

    // MARK: - No question yet

    @ViewBuilder
    private func noQuestionSection(for m: Member) -> some View {
        if m.isTriviaMaster {
            PostQuestionForm(model: model, member: m)
        } else {
            FieldPanel {
                VStack(alignment: .leading, spacing: 8) {
                    StencilTitle("STAND BY", size: 18, solid: true)
                    Text("No trivia has been posted yet today. Check back soon, soldier.")
                        .font(Theme.label(15, weight: .regular)).foregroundStyle(.black)
                }
            }
        }
    }

    // MARK: - Master

    @ViewBuilder
    private func masterSection(q: TriviaQuestion, m: Member) -> some View {
        if !q.revealed {
            ParticipationPanel(model: model)
            FieldPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("You control the reveal. Once you reveal, everyone sees all answers and you grade them.")
                        .font(Theme.label(14, weight: .regular)).foregroundStyle(.black)
                    Button("REVEAL ANSWERS (\(model.answeredCount)/\(model.totalCount))") {
                        Task { await model.reveal(member: m) }
                    }
                    .buttonStyle(JoeButtonStyle())
                }
            }
        } else {
            GradingPanel(model: model, member: m)
        }
    }

    // MARK: - Member

    @ViewBuilder
    private func memberSection(q: TriviaQuestion, m: Member) -> some View {
        if q.revealed {
            ResultsPanel(model: model, member: m)
        } else if let mine = model.myResponse {
            AnsweredPanel(answer: mine.answer, model: model, member: m)
        } else {
            AnswerForm(model: model, member: m)
        }
    }
}

// MARK: - Master: post a new question

struct PostQuestionForm: View {
    let model: TodayModel
    let member: Member
    @State private var prompt = ""
    @State private var answer = ""
    @State private var working = false

    var body: some View {
        FieldPanel {
            VStack(alignment: .leading, spacing: 12) {
                StencilTitle("POST TODAY'S TRIVIA", size: 17, solid: true)

                fieldLabel("QUESTION")
                TextEditor(text: $prompt)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(8).background(Theme.surfaceHi)
                    .foregroundStyle(Theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))

                fieldLabel("CORRECT ANSWER (only you see this)")
                TextField("", text: $answer, prompt: Text("e.g. Conrad Hauser").foregroundColor(Theme.textDim))
                    .padding(10).background(Theme.surfaceHi)
                    .foregroundStyle(Theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))

                Button {
                    working = true
                    Task {
                        _ = await model.post(prompt: prompt.trimmed, answer: answer.trimmed, by: member)
                        working = false
                    }
                } label: {
                    if working { ProgressView().tint(.black) } else { Text("POST QUESTION") }
                }
                .buttonStyle(JoeButtonStyle())
                .disabled(working || prompt.trimmed.isEmpty || answer.trimmed.isEmpty)
                .opacity(prompt.trimmed.isEmpty || answer.trimmed.isEmpty ? 0.5 : 1)
            }
        }
    }
}

// MARK: - Master: grading after reveal

struct GradingPanel: View {
    let model: TodayModel
    let member: Member

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StencilTitle("GRADE RESPONSES", size: 17)

            if model.responses.isEmpty {
                Text("No one answered today.").font(Theme.label(14)).foregroundStyle(.black)
            }

            ForEach(model.responses) { r in
                FieldPanel {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(r.name).font(Theme.label(15, weight: .bold)).foregroundStyle(.black)
                            Spacer()
                            gradeBadge(r.isCorrect)
                        }
                        Text(r.answer).font(Theme.label(17, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        HStack(spacing: 10) {
                            Button {
                                Task { await model.grade(r, correct: true, member: member) }
                            } label: { Label("Correct", systemImage: "checkmark") }
                                .buttonStyle(GradeButtonStyle(active: r.isCorrect == true, color: Theme.oliveDrab))
                            Button {
                                Task { await model.grade(r, correct: false, member: member) }
                            } label: { Label("Wrong", systemImage: "xmark") }
                                .buttonStyle(GradeButtonStyle(active: r.isCorrect == false, color: Theme.red))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Member: answer form / answered / results

struct AnswerForm: View {
    let model: TodayModel
    let member: Member
    @State private var answer = ""
    @State private var working = false

    var body: some View {
        FieldPanel {
            VStack(alignment: .leading, spacing: 12) {
                StencilTitle("YOUR ANSWER", size: 17, solid: true)
                Text("No one sees your answer until the trivia master reveals.")
                    .font(Theme.label(13, weight: .regular)).foregroundStyle(.black)
                TextField("", text: $answer, prompt: Text("Type your answer…").foregroundColor(Theme.textDim))
                    .padding(12).background(Theme.surfaceHi)
                    .foregroundStyle(Theme.textPrimary)
                    .font(Theme.label(18, weight: .medium))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                Button {
                    working = true
                    Task { _ = await model.submit(answer: answer.trimmed, member: member); working = false }
                } label: {
                    if working { ProgressView().tint(.black) } else { Text("LOCK IN ANSWER") }
                }
                .buttonStyle(JoeButtonStyle())
                .disabled(working || answer.trimmed.isEmpty)
                .opacity(answer.trimmed.isEmpty ? 0.5 : 1)
            }
        }
    }
}

struct AnsweredPanel: View {
    let answer: String
    let model: TodayModel
    let member: Member
    @State private var editing = false
    @State private var draft = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FieldPanel {
                VStack(alignment: .leading, spacing: 10) {
                    StencilTitle("ANSWER LOCKED IN", size: 16, solid: true)
                    if editing {
                        TextField("", text: $draft)
                            .padding(12).background(Theme.surfaceHi)
                            .foregroundStyle(Theme.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                        HStack {
                            Button("SAVE") {
                                working = true
                                Task {
                                    _ = await model.submit(answer: draft.trimmed, member: member)
                                    working = false; editing = false
                                }
                            }.buttonStyle(JoeButtonStyle()).disabled(draft.trimmed.isEmpty)
                            Button("CANCEL") { editing = false }
                                .buttonStyle(JoeButtonStyle(tint: Theme.surfaceHi, fg: .black))
                        }
                    } else {
                        Text(answer).font(Theme.label(19, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Waiting for the trivia master to reveal. You can still change it until then.")
                            .font(Theme.label(13, weight: .regular)).foregroundStyle(.black)
                        Button("EDIT ANSWER") { draft = answer; editing = true }
                            .buttonStyle(JoeButtonStyle(tint: Theme.surfaceHi, fg: .black))
                    }
                }
            }
            ParticipationPanel(model: model)
        }
    }
}

struct ResultsPanel: View {
    let model: TodayModel
    let member: Member

    private var mine: ResponseWithName? { model.responses.first { $0.memberId == member.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let mine {
                FieldPanel {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            StencilTitle("YOUR RESULT", size: 15, solid: true)
                            Text(mine.answer).font(Theme.label(18, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        }
                        Spacer()
                        gradeBadge(mine.isCorrect)
                    }
                }
            }
            StencilTitle("ALL ANSWERS", size: 16)
            ForEach(model.responses) { r in
                FieldPanel {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.name).font(Theme.label(14, weight: .bold)).foregroundStyle(.black)
                            Text(r.answer).font(Theme.label(16, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        }
                        Spacer()
                        gradeBadge(r.isCorrect)
                    }
                }
            }
        }
    }
}

// MARK: - Shared bits

struct ParticipationPanel: View {
    let model: TodayModel
    var body: some View {
        FieldPanel {
            VStack(alignment: .leading, spacing: 8) {
                StencilTitle("ROLL CALL  \(model.answeredCount)/\(model.totalCount)", size: 15, solid: true)
                FlowRow(items: model.participation) { p in
                    HStack(spacing: 5) {
                        Image(systemName: p.hasAnswered ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.black)
                        Text(p.displayName).font(Theme.label(13, weight: .medium))
                            .foregroundStyle(p.hasAnswered ? Theme.textPrimary : Theme.textDim)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Theme.surfaceHi).clipShape(Capsule())
                }
            }
        }
    }
}

@ViewBuilder
func gradeBadge(_ isCorrect: Bool?) -> some View {
    switch isCorrect {
    case .some(true):  RoleTag(text: "CORRECT", color: Theme.oliveDrab)
    case .some(false): RoleTag(text: "WRONG", color: Theme.red)
    case .none:        RoleTag(text: "UNGRADED", color: Theme.surfaceHi)
    }
}

func fieldLabel(_ t: String) -> some View {
    Text(t).font(Theme.label(12, weight: .bold)).tracking(1).foregroundStyle(.black)
}

struct GradeButtonStyle: ButtonStyle {
    let active: Bool
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(14, weight: .bold))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(active ? color : Theme.background)
            .foregroundStyle(active ? Theme.textPrimary : Theme.textDim)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color.opacity(active ? 1 : 0.4)))
    }
}

func todayLabel() -> String {
    let f = DateFormatter()
    f.timeZone = Config.timeZone
    f.dateFormat = "EEEE, MMMM d"
    return f.string(from: Date())
}

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

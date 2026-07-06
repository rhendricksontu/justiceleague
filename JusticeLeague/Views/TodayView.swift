import SwiftUI

struct TodayView: View {
    @Environment(AppState.self) private var app
    @State private var model = TodayModel()
    @State private var lbModel = LeaderboardModel()
    @State private var selectedDay = CalFmt.central.startOfDay(for: Date())

    private var member: Member? { app.currentMember }
    private var startOfToday: Date { CalFmt.central.startOfDay(for: Date()) }
    private var isToday: Bool { CalFmt.central.isDate(selectedDay, inSameDayAs: startOfToday) }
    // Anyone can page back through history; only the master goes into the future.
    private var canGoForward: Bool {
        selectedDay < startOfToday || member?.isTriviaMaster == true
    }

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
            .onChange(of: selectedDay) { _, _ in Task { await reloadDay() } }
            #if DEBUG
            .onAppear {
                if let s = ProcessInfo.processInfo.environment["START_DAY"] {
                    let f = DateFormatter(); f.timeZone = Config.timeZone; f.dateFormat = "yyyy-MM-dd"
                    if let d = f.date(from: s) { selectedDay = CalFmt.central.startOfDay(for: d) }
                }
            }
            #endif
        }
    }

    private func refreshAll() async {
        model.day = CalFmt.dayKey(selectedDay)
        if let m = member { await model.load(member: m) }
        await lbModel.load()
    }

    private func reloadDay() async {
        model.day = CalFmt.dayKey(selectedDay)
        if let m = member { await model.load(member: m) }
    }

    private func shiftDay(_ delta: Int) {
        if let d = CalFmt.central.date(byAdding: .day, value: delta, to: selectedDay) { selectedDay = d }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { shiftDay(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
            }
            Spacer()
            Text(dayLabel.uppercased())
                .font(Theme.label(13, weight: .bold)).tracking(2).foregroundStyle(.black)
            Spacer()
            Button { shiftDay(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
            }
            .disabled(!canGoForward)
            .opacity(canGoForward ? 1 : 0.25)
        }
    }

    private var dayLabel: String {
        let f = DateFormatter(); f.timeZone = Config.timeZone; f.dateFormat = "EEEE, MMMM d"
        let base = f.string(from: selectedDay)
        return isToday ? "TODAY · \(base)" : base
    }

    @ViewBuilder
    private func content(for m: Member) -> some View {
        if let q = model.question {
            // Question prompt panel — shown to everyone.
            FieldPanel {
                VStack(alignment: .leading, spacing: 10) {
                    StencilTitle("MISSION BRIEFING", size: 15, solid: true)
                    Text(q.prompt)
                        .font(Theme.label(19, weight: .regular))
                        .foregroundStyle(Theme.textPrimary)
                    if q.revealed, let key = model.answerKey {
                        Divider().overlay(Theme.oliveDrab)
                        (Text("Answer: ").font(Theme.label(16, weight: .bold)).foregroundColor(.black)
                            + Text(key.correctAnswer).font(Theme.label(16, weight: .regular)).foregroundColor(.black))
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
                    Text(isToday ? "No trivia has been posted yet today. Check back soon, soldier."
                                 : "No trivia was posted for this day.")
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
            // Days lock automatically once they end; the master can override.
            let locked = q.gradingLocked ?? (selectedDay < startOfToday)
            GradingPanel(model: model, member: m, locked: locked) {
                Task { await model.setGradingLock(!locked, member: m) }
            }
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
                StencilTitle("POST TRIVIA", size: 17, solid: true)

                fieldLabel("QUESTION")
                TextEditor(text: $prompt)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(8).background(Theme.surfaceHi)
                    .foregroundStyle(Theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))

                fieldLabel("CORRECT ANSWER (only you see this)")
                TextField("", text: $answer)
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
    let locked: Bool
    let onToggleLock: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                    StencilTitle(locked ? "VIEW RESPONSES" : "GRADE RESPONSES", size: 18)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack {
                    Button(action: onToggleLock) {
                        Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 18, weight: .bold)).foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(locked ? "Unlock grading" : "Lock grading")
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                }
            }

            if expanded {
                if model.responses.isEmpty {
                    Text("No one answered today.").font(Theme.label(14)).foregroundStyle(.black)
                }

                ForEach(model.responses) { r in
                    if locked {
                        HStack(spacing: 12) {
                            LabeledAvatar(avatarId: r.avatar, size: 44, nameSize: 10)
                            (Text("\(r.name): ").font(Theme.label(16, weight: .semibold)).foregroundColor(.black)
                                + Text(r.answer).font(Theme.label(16, weight: .regular)).foregroundColor(.black))
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(answerCardColor(r.isCorrect))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
                    } else {
                        FieldPanel {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 12) {
                                    LabeledAvatar(avatarId: r.avatar, size: 44, nameSize: 10)
                                    (Text("\(r.name): ").font(Theme.label(16, weight: .semibold)).foregroundColor(.black)
                                        + Text(r.answer).font(Theme.label(16, weight: .regular)).foregroundColor(.black))
                                    Spacer(minLength: 0)
                                }
                                HStack(spacing: 10) {
                                    Button {
                                        Task { await model.grade(r, correct: true, member: member) }
                                    } label: { Label("Correct", systemImage: "checkmark") }
                                        .buttonStyle(GradeButtonStyle(active: r.isCorrect == true, color: Avatars.badgeGreen))
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
                TextField("", text: $answer)
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
                            .buttonStyle(JoeButtonStyle())
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
    @State private var showAllAnswers = false

    private var mine: ResponseWithName? { model.responses.first { $0.memberId == member.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let mine {
                (Text("Your Response: ").font(Theme.label(16, weight: .bold)).foregroundColor(.black)
                    + Text(mine.answer).font(Theme.label(16, weight: .regular)).foregroundColor(.black))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(answerCardColor(mine.isCorrect))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
            }
            Button { withAnimation(.easeInOut(duration: 0.2)) { showAllAnswers.toggle() } } label: {
                ZStack {
                    StencilTitle("View Responses", size: 18)
                        .frame(maxWidth: .infinity)
                    HStack {
                        Spacer()
                        Image(systemName: showAllAnswers ? "chevron.up" : "chevron.down")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                    }
                }
            }
            .buttonStyle(.plain)

            if showAllAnswers {
                ForEach(model.responses) { r in
                    HStack(spacing: 12) {
                        LabeledAvatar(avatarId: r.avatar, size: 44, nameSize: 10)
                        (Text("\(r.name): ").font(Theme.label(16, weight: .semibold)).foregroundColor(.black)
                            + Text(r.answer).font(Theme.label(16, weight: .regular)).foregroundColor(.black))
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(answerCardColor(r.isCorrect))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
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
                        if p.hasAnswered {
                            ZStack {
                                Circle().fill(Avatars.badgeGreen)
                                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            }
                            .frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(.black)
                        }
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
    case .some(true):  gradePill("CORRECT", Avatars.badgeGreen)
    case .some(false): gradePill("WRONG", Theme.red)
    case .none:        gradePill("UNGRADED", Theme.cyan)
    }
}

// Tinted card background for a graded answer — green when correct, red when
// wrong, neutral until graded. Tinted (not solid) so the green avatar and text
// stay readable on top.
func answerCardColor(_ isCorrect: Bool?) -> Color {
    switch isCorrect {
    case .some(true):  return Avatars.badgeGreen.opacity(0.22)
    case .some(false): return Theme.red.opacity(0.18)
    case .none:        return Theme.surface
    }
}

func gradePill(_ text: String, _ color: Color) -> some View {
    Text(text)
        .font(Theme.label(11, weight: .bold)).tracking(1)
        .foregroundStyle(Theme.onPrimary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color).clipShape(Capsule())
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
            .foregroundStyle(active ? Theme.onPrimary : .black)
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

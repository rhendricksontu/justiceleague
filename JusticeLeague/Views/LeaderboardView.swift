import SwiftUI

@MainActor
@Observable
final class LeaderboardModel {
    var monthlyScores: [MonthlyScore] = []
    var winners: [MonthlyWinner] = []
    var avatars: [UUID: String] = [:]   // memberId -> chosen avatar id
    var loading = true

    func load() async {
        loading = true
        var scores = (try? await TriviaService.monthlyScores(monthStart: MonthFmt.startOfCurrentMonth())) ?? []
        // Most points first, then name A–Z.
        scores.sort { a, b in
            a.correctCount != b.correctCount
                ? a.correctCount > b.correctCount
                : a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
        monthlyScores = scores
        winners = (try? await TriviaService.monthlyWinners()) ?? []
        let members = (try? await TriviaService.allMembers()) ?? []
        avatars = Dictionary(uniqueKeysWithValues: members.compactMap { m in m.avatar.map { (m.id, $0) } })
        loading = false
    }

    // Group winners by month for the year-long history list.
    var winnersByMonth: [(month: Date, names: [String], count: Int)] {
        let grouped = Dictionary(grouping: winners, by: { $0.month })
        return grouped
            .map { (month: $0.key, names: $0.value.map(\.displayName).sorted(), count: $0.value.first?.correctCount ?? 0) }
            .sorted { $0.month > $1.month }
    }
}

// Leaderboard shown as a section beneath the daily trivia. Owns no nav bar of
// its own; the parent (TodayView) supplies the model and pull-to-refresh.
struct LeaderboardSection: View {
    let model: LeaderboardModel
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StencilTitle("Current Leaderboard", size: 18)
                .frame(maxWidth: .infinity)

            Picker("", selection: $tab) {
                Text("THIS MONTH").tag(0)
                Text("HALL OF FAME").tag(1)
            }
            .pickerStyle(.segmented)

            if model.loading {
                ProgressView().tint(Theme.cyan).frame(maxWidth: .infinity).padding(.top, 20)
            } else if tab == 0 {
                monthlyBoard
            } else {
                hallOfFame
            }
        }
    }

    @ViewBuilder
    private var monthlyBoard: some View {
        Text(MonthFmt.label(currentMonthDate()).uppercased())
            .font(Theme.label(13, weight: .bold)).tracking(2).foregroundStyle(.black)
        if model.monthlyScores.isEmpty {
            emptyNote("No correct answers logged yet this month. Get in the game!")
        } else {
            ForEach(model.monthlyScores) { score in
                LeaderRow(avatarId: model.avatars[score.memberId], name: score.displayName, count: score.correctCount)
            }
        }
    }

    @ViewBuilder
    private var hallOfFame: some View {
        Text("MONTHLY CHAMPIONS")
            .font(Theme.label(13, weight: .bold)).tracking(2).foregroundStyle(.black)
        if model.winnersByMonth.isEmpty {
            emptyNote("No champions crowned yet. The first month's winner will appear here.")
        } else {
            ForEach(model.winnersByMonth, id: \.month) { entry in
                FieldPanel {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "trophy.fill").font(.title2).foregroundStyle(.black)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(MonthFmt.label(entry.month)).font(Theme.label(13, weight: .bold)).foregroundStyle(.black)
                            Text(entry.names.joined(separator: " & "))
                                .font(Theme.label(18, weight: .heavy)).foregroundStyle(.black)
                        }
                        Spacer()
                        VStack {
                            Text("\(entry.count)").font(Theme.stencil(24)).foregroundStyle(.black)
                            Text("CORRECT").font(Theme.label(9, weight: .bold)).foregroundStyle(.black)
                        }
                    }
                }
            }
        }
    }

    private func emptyNote(_ t: String) -> some View {
        FieldPanel {
            Text(t).font(Theme.label(14, weight: .regular)).foregroundStyle(.black)
        }
    }
}

struct LeaderRow: View {
    let avatarId: String?
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            AvatarBadge(avatar: Avatars.find(avatarId), size: 40)
            Text(name).font(Theme.label(17, weight: .bold)).foregroundStyle(.black)
            Spacer()
            Text("\(count)").font(Theme.stencil(22)).foregroundStyle(.black)
            Text("pts").font(Theme.label(12)).foregroundStyle(.black)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 1))
    }
}

private func currentMonthDate() -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = Config.timeZone
    return cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
}

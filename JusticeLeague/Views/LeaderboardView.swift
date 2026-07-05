import SwiftUI

@MainActor
@Observable
final class LeaderboardModel {
    var monthlyScores: [MonthlyScore] = []
    var winners: [MonthlyWinner] = []
    var loading = true

    func load() async {
        loading = true
        monthlyScores = (try? await TriviaService.monthlyScores(monthStart: MonthFmt.startOfCurrentMonth())) ?? []
        winners = (try? await TriviaService.monthlyWinners()) ?? []
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

struct LeaderboardView: View {
    @State private var model = LeaderboardModel()
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    Picker("", selection: $tab) {
                        Text("THIS MONTH").tag(0)
                        Text("HALL OF FAME").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(16)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if model.loading {
                                ProgressView().tint(Theme.cyan).frame(maxWidth: .infinity).padding(.top, 40)
                            } else if tab == 0 {
                                monthlyBoard
                            } else {
                                hallOfFame
                            }
                        }
                        .padding(20)
                    }
                    .refreshable { await model.load() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { StencilTitle("Current Leaderboard", size: 20) } }
            .task { await model.load() }
        }
    }

    @ViewBuilder
    private var monthlyBoard: some View {
        Text(MonthFmt.label(currentMonthDate()).uppercased())
            .font(Theme.label(13, weight: .bold)).tracking(2).foregroundStyle(.black)
        if model.monthlyScores.isEmpty {
            emptyNote("No correct answers logged yet this month. Get in the game!")
        } else {
            ForEach(Array(model.monthlyScores.enumerated()), id: \.element.id) { idx, score in
                RankRow(rank: idx + 1, name: score.displayName, count: score.correctCount)
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
                        Image(systemName: "trophy.fill").font(.title2).foregroundStyle(Theme.gold)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(MonthFmt.label(entry.month)).font(Theme.label(13, weight: .bold)).foregroundStyle(Theme.tan)
                            Text(entry.names.joined(separator: " & "))
                                .font(Theme.label(18, weight: .heavy)).foregroundStyle(Theme.textPrimary)
                        }
                        Spacer()
                        VStack {
                            Text("\(entry.count)").font(Theme.stencil(24)).foregroundStyle(Theme.gold)
                            Text("CORRECT").font(Theme.label(9, weight: .bold)).foregroundStyle(Theme.textDim)
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

struct RankRow: View {
    let rank: Int
    let name: String
    let count: Int

    private var rankColor: Color {
        switch rank { case 1: return Theme.gold; case 2: return Theme.tan; case 3: return Theme.red; default: return Theme.oliveDrab }
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(rank)")
                .font(Theme.stencil(22))
                .foregroundStyle(rank <= 3 ? Theme.onPrimary : Theme.textPrimary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(rank <= 3 ? rankColor : Theme.surfaceHi))
            Text(name).font(Theme.label(17, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("\(count)").font(Theme.stencil(22)).foregroundStyle(Theme.gold)
            Text("pts").font(Theme.label(12)).foregroundStyle(Theme.textDim)
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

import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var app
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            TodayView()
                .tabItem { Label("Trivia", systemImage: "target") }.tag(0)

            LeaderboardView()
                .tabItem { Label("Leaderboard", systemImage: "medal.fill") }.tag(1)

            if app.currentMember?.isAdmin == true {
                AdminView()
                    .tabItem { Label("Roster", systemImage: "person.3.fill") }.tag(2)
            }

            ProfileView()
                .tabItem { Label("Me", systemImage: "person.crop.circle") }.tag(3)
        }
        .task { await app.refreshMember() }
        #if DEBUG
        .onAppear {
            if let t = ProcessInfo.processInfo.environment["START_TAB"], let i = Int(t) { selection = i }
        }
        #endif
    }
}

struct ProfileView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(spacing: 24) {
                    JoeWordmark(size: 34, tagline: "FOUNDING FATHER")
                        .padding(.top, 16)

                    if let m = app.currentMember {
                        FieldPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                StencilTitle(m.displayName, size: 22, solid: true)
                                Text(PhoneUtil.pretty(m.phone))
                                    .font(Theme.label(15))
                                    .foregroundStyle(.black)
                                HStack(spacing: 8) {
                                    if m.isAdmin { RoleTag(text: "ADMIN") }
                                    if m.isTriviaMaster { RoleTag(text: "TRIVIA MASTER") }
                                    if !m.isAdmin && !m.isTriviaMaster { RoleTag(text: "MEMBER") }
                                }
                            }
                        }
                    }

                    Spacer()
                    Button("SIGN OUT") { Task { await app.signOut() } }
                        .buttonStyle(JoeButtonStyle(tint: Theme.red, fg: Theme.onPrimary))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .navigationTitle("")
        }
    }
}

struct RoleTag: View {
    let text: String
    var color: Color = Theme.cyan   // kept for call-site compatibility; all pills are cyan
    var body: some View {
        Text(text)
            .font(Theme.label(11, weight: .bold))
            .tracking(1)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.cyan)
            .clipShape(Capsule())
    }
}

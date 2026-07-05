import SwiftUI

@main
struct JusticeLeagueApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(Theme.gold)
                .task { await app.bootstrap() }
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        switch app.phase {
        case .loading:
            SplashView()
        case .signedOut:
            LoginView()
        case .signedIn:
            MainTabView()
        }
    }
}

struct SplashView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 14) {
                StencilTitle("Justice League", size: 34)
                Text("A REAL AMERICAN HERO")
                    .font(Theme.label(12, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(Theme.tan)
                ProgressView().tint(Theme.gold).padding(.top, 8)
            }
        }
    }
}

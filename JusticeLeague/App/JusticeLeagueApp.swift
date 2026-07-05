import SwiftUI

@main
struct JusticeLeagueApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .preferredColorScheme(.light)
                .tint(Theme.cyan)
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
            VStack(spacing: 18) {
                JoeWordmark(size: 34)
                ProgressView().tint(Theme.cyan).padding(.top, 8)
            }
        }
    }
}

import UIKit
import UserNotifications

// Owns remote-notification registration and uploads the APNs device token to
// the backend (device_tokens) once the member is signed in. Push alerts for new
// chat messages are sent server-side by the `send-push` edge function.
@MainActor
final class PushManager: NSObject {
    static let shared = PushManager()

    private var deviceToken: String?
    private var signedIn = false

    // Called after a successful sign-in / session restore.
    func onSignIn() async {
        signedIn = true
        await requestAuthorizationAndRegister()
        await uploadTokenIfReady()
    }

    func onSignOut() {
        signedIn = false
    }

    // The AppDelegate hands us the token string from APNs.
    func didRegister(token: String) {
        deviceToken = token
        Task { await uploadTokenIfReady() }
    }

    private func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func uploadTokenIfReady() async {
        guard signedIn, let token = deviceToken else { return }
        try? await TriviaService.registerDeviceToken(token)
    }
}

// UIKit app delegate, bridged into SwiftUI via @UIApplicationDelegateAdaptor.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in PushManager.shared.didRegister(token: hex) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator / no-entitlement builds land here; nothing to do.
    }

    // Show banners even when the app is in the foreground.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }
}

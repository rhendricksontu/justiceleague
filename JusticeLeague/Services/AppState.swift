import Foundation
import Observation
import Supabase

@MainActor
@Observable
final class AppState {
    enum Phase { case loading, signedOut, signedIn }

    var phase: Phase = .loading
    var currentMember: Member?
    var loginError: String?
    var isWorkingOnLogin = false

    private var client: SupabaseClient { SupabaseManager.client }

    struct LoginResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let member: Member
        enum CodingKeys: String, CodingKey {
            case member
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    // Restore a persisted session on launch, if any.
    func bootstrap() async {
        #if DEBUG
        // Testing affordance: auto-sign-in when a phone is injected via the
        // environment (SIMCTL_CHILD_AUTOLOGIN_PHONE). Never set in production.
        if let p = ProcessInfo.processInfo.environment["AUTOLOGIN_PHONE"], !p.isEmpty {
            await signIn(phone: p)
            if phase == .signedIn { return }
        }
        #endif
        do {
            let session = try await client.auth.session
            if let member = try await loadMember(for: session) {
                currentMember = member
                phase = .signedIn
                return
            }
        } catch {
            // no valid session
        }
        phase = .signedOut
    }

    private func loadMember(for session: Session) async throws -> Member? {
        guard
            let raw = session.user.appMetadata["member_id"]?.stringValue,
            let memberId = UUID(uuidString: raw)
        else { return nil }

        let members: [Member] = try await client
            .from("members")
            .select()
            .eq("id", value: memberId)
            .limit(1)
            .execute()
            .value
        return members.first
    }

    func signIn(phone: String) async {
        loginError = nil
        isWorkingOnLogin = true
        defer { isWorkingOnLogin = false }

        do {
            let resp = try await callLogin(phone: phone)
            try await client.auth.setSession(
                accessToken: resp.accessToken,
                refreshToken: resp.refreshToken
            )
            currentMember = resp.member
            phase = .signedIn
        } catch let e as LoginError {
            loginError = e.userMessage
        } catch {
            loginError = "Something went wrong. Check your connection and try again."
        }
    }

    func signOut() async {
        try? await client.auth.signOut()
        currentMember = nil
        phase = .signedOut
    }

    // A member editing their own name + phone.
    func updateMyProfile(name: String, phone: String) async -> Bool {
        do {
            try await TriviaService.updateMyProfile(name: name, phone: phone)
            await refreshMember()
            return true
        } catch {
            return false
        }
    }

    // A member choosing their G.I. Joe avatar (fails if already taken).
    func setMyAvatar(_ id: String?) async -> Bool {
        do {
            try await TriviaService.setMyAvatar(id)
            await refreshMember()
            return true
        } catch {
            return false
        }
    }

    // Re-fetch the current member (roles may have changed).
    func refreshMember() async {
        guard let id = currentMember?.id else { return }
        let members: [Member]? = try? await client
            .from("members").select().eq("id", value: id).limit(1).execute().value
        if let m = members?.first { currentMember = m }
    }

    // MARK: - login edge function

    enum LoginError: Error {
        case notOnRoster, inactive, invalidPhone, server(String)
        var userMessage: String {
            switch self {
            case .notOnRoster: return "That number isn't on the roster yet. Ask the admin to add you."
            case .inactive:    return "Your access is currently turned off. Contact the admin."
            case .invalidPhone: return "That doesn't look like a valid phone number."
            case .server(let m): return m.isEmpty ? "Login failed. Try again." : m
            }
        }
    }

    private func callLogin(phone: String) async throws -> LoginResponse {
        var req = URLRequest(url: Config.supabaseURL.appendingPathComponent("functions/v1/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["phone": phone])

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse

        if http?.statusCode == 200 {
            return try JSONDecoder().decode(LoginResponse.self, from: data)
        }

        // Map known error codes from the function.
        let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        switch code {
        case "not_on_roster": throw LoginError.notOnRoster
        case "inactive":      throw LoginError.inactive
        case "invalid_phone": throw LoginError.invalidPhone
        default:              throw LoginError.server("")
        }
    }
}

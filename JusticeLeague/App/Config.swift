import Foundation

// Supabase project connection. The anon key is a public client key — all access is
// governed by Row Level Security on the server, so it is safe to ship in the app.
// The service_role key is NEVER placed here; it lives only in the `login` edge function.
enum Config {
    static let supabaseURL = URL(string: "https://lwapoxbgtfutugdeudgb.supabase.co")!
    static let supabaseAnonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx3YXBveGJndGZ1dHVnZGV1ZGdiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNzUxNTAsImV4cCI6MjA5ODg1MTE1MH0.yUYHKItYH_oiknkr87KzpLw_PxNROsoZ78IbIl6bZI8"

    // Trivia days roll over at midnight Central Time (Oklahoma).
    static let timeZone = TimeZone(identifier: "America/Chicago")!

    // Giphy API key for in-app GIF search. Get a FREE key in ~2 minutes at
    // https://developers.giphy.com → Create an App → choose "API" → copy the
    // API Key, and paste it below. GIF search stays empty until this is set.
    static let giphyKey = "PASTE_YOUR_GIPHY_API_KEY"
    static var giphyConfigured: Bool { giphyKey != "PASTE_YOUR_GIPHY_API_KEY" && !giphyKey.isEmpty }
}

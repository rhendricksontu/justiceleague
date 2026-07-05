# Justice League OK

A native **iOS (SwiftUI)** app for the Justice League men's group, themed after the
1983 **G.I. Joe** series. First feature: **daily trivia** with a trivia master,
hidden answers, manual reveal, grading, and monthly leaderboards.

## Stack

- **iOS app** — SwiftUI, Swift 6, iOS 17+. Project generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from [`project.yml`](project.yml).
- **Backend** — [Supabase](https://supabase.com) (Postgres + Auth + Edge Functions), project ref `lwapoxbgtfutugdeudgb`.
- **Auth** — phone number only, no verification code. The [`login`](supabase/functions/login/index.ts) edge function maps a phone to a roster member and mints a Supabase session; **Row Level Security** enforces all authorization.

## Project layout

```
JusticeLeague/            SwiftUI app
  App/                    entry point + Config (Supabase URL / anon key)
  Theme/                  G.I. Joe theme (colors, stencil fonts, components)
  Models/                 Codable models
  Services/               Supabase client, AppState (auth), TriviaService
  Views/                  Login, Today (trivia), Leaderboard, Admin, Profile
  Assets.xcassets/        app icon + theme colors
supabase/
  migrations/             schema, RLS policies, leaderboard views, helper fns
  functions/login/        phone-only login edge function
```

## How the trivia flow works

1. The **trivia master** posts the day's question + correct answer (answer stored
   separately, hidden by RLS).
2. **Members** submit free-text answers. Before reveal, RLS lets each member see
   **only their own** answer, and no one can read the answer key.
3. The master taps **Reveal** — now everyone sees all answers and the correct one.
4. The master **grades** each response right/wrong.
5. Leaderboards tally correct answers per month; monthly champions land in the
   Hall of Fame. Daily boundaries use **Central Time**.

## Development

```bash
# Regenerate the Xcode project after editing project.yml
xcodegen generate

# Build for the simulator
xcodebuild -project JusticeLeague.xcodeproj -scheme JusticeLeague \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Push DB schema changes
supabase db push

# Deploy the login function
supabase functions deploy login
```

The anon key in `App/Config.swift` is a public client key protected by RLS — safe
to ship. The service-role key is **never** committed; it lives only in the edge
function's runtime environment.

### Roles

- **Admin** — manages the roster (add members, assign roles, deactivate).
- **Trivia master** — posts questions, reveals, grades. Assignable to anyone.
- **Member** — answers and views leaderboards.

## Roadmap

- Push notifications ("Today's trivia is live!", "Answers revealed!")
- TestFlight distribution (requires Apple Developer Program enrollment)

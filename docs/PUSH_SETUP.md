# Push Notifications — Setup

Group-chat messages trigger a push to every other member's device. The app
side (permission prompt, token registration, `device_tokens` table, insert
trigger, and the `send-push` edge function) is **already built and deployed**.
To actually deliver alerts you must supply your Apple APNs credentials and run
on a **real device** (the iOS Simulator can register a token but Apple will not
deliver pushes to it).

## 1. Create an APNs Auth Key (one-time)

1. Go to <https://developer.apple.com/account/resources/authkeys/list>.
2. Click **+**, name it (e.g. "Justice League Push"), check **Apple Push
   Notifications service (APNs)**, Continue → Register.
3. **Download the `.p8` file** (you can only download it once) and note the
   **Key ID** (10 chars).
4. Find your **Team ID** (10 chars) at the top-right of the developer portal or
   under Membership.

## 2. Set the edge-function secrets

Run these from the repo root (paste your real values). The `.p8` is passed as
its full text including the BEGIN/END lines:

```bash
supabase secrets set APNS_KEY_ID=XXXXXXXXXX
supabase secrets set APNS_TEAM_ID=YYYYYYYYYY
supabase secrets set APNS_BUNDLE_ID=com.justiceleagueok.app
supabase secrets set APNS_ENV=sandbox            # dev builds from Xcode
supabase secrets set APNS_PRIVATE_KEY="$(cat /path/to/AuthKey_XXXXXXXXXX.p8)"
```

- `APNS_ENV=sandbox` is correct for apps built and run from Xcode on a device.
- Use `APNS_ENV=production` for TestFlight / App Store builds.
- `PUSH_TRIGGER_SECRET` is already set (it matches the DB trigger). Leave it.

No redeploy needed after setting secrets — the function reads them at runtime.

## 3. Enable the capability in Xcode / signing

The app already ships an entitlement (`aps-environment`). For a **device**
build you also need a matching provisioning profile:

1. Open `JusticeLeague.xcodeproj` in Xcode.
2. Select the target → **Signing & Capabilities**.
3. Pick your **Team**; ensure **Push Notifications** appears in the capability
   list (add it with **+ Capability** if not).
4. Xcode will regenerate a provisioning profile that includes push.

> Note: `project.yml` (XcodeGen) already wires `CODE_SIGN_ENTITLEMENTS` to
> `JusticeLeague/JusticeLeague.entitlements`. If you regenerate the project with
> `xcodegen generate`, re-open in Xcode and confirm the Team is still selected.

## 4. Test

1. Build to a real iPhone from Xcode and sign in. Accept the notification
   prompt. The app registers a token into `public.device_tokens`.
2. On a second member's phone (or via the API), post a chat message.
3. The first device should receive a banner: **"<Sender> · The League"**.

If nothing arrives, check the function logs:
`https://supabase.com/dashboard/project/lwapoxbgtfutugdeudgb/functions/send-push/logs`
— `apns_not_configured` means a secret is missing; `no_devices` means no other
tokens are registered yet.

## How it works

```
message INSERT
   └─ trigger on_message_created (pg_net)
         └─ POST /functions/v1/send-push  { message_id }   (x-webhook-secret)
               ├─ loads message + sender name (service role)
               ├─ loads every OTHER member's device tokens
               ├─ mints an APNs ES256 provider JWT from the .p8
               └─ POSTs an alert to APNs for each token
                     └─ prunes tokens APNs reports as dead (400/410)
```

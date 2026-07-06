// Fan out a new chat message to every other member's devices via APNs.
// Invoked by the `on_message_created` trigger (pg_net) with { message_id }.
//
// Required function secrets:
//   APNS_KEY_ID       – the 10-char Key ID of your APNs auth key (.p8)
//   APNS_TEAM_ID      – your 10-char Apple Developer Team ID
//   APNS_PRIVATE_KEY  – the full PEM contents of the .p8 auth key
//   APNS_BUNDLE_ID    – com.justiceleagueok.app
//   APNS_ENV          – "sandbox" (dev builds) or "production" (App Store/TestFlight)
//   PUSH_TRIGGER_SECRET – shared secret matching the trigger's x-webhook-secret
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY") ?? "";
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.justiceleagueok.app";
const APNS_ENV = Deno.env.get("APNS_ENV") ?? "sandbox";
const TRIGGER_SECRET = Deno.env.get("PUSH_TRIGGER_SECRET") ?? "";

const APNS_HOST = APNS_ENV === "production"
  ? "https://api.push.apple.com"
  : "https://api.sandbox.push.apple.com";

function b64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlStr(s: string): string {
  return b64url(new TextEncoder().encode(s));
}

// Import the .p8 (PKCS#8 EC P-256) private key for ES256 signing.
async function importKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der.buffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

// A short-lived APNs provider JWT (valid ~1h; we mint one per invocation).
async function makeProviderToken(key: CryptoKey): Promise<string> {
  const header = { alg: "ES256", kid: APNS_KEY_ID };
  const payload = { iss: APNS_TEAM_ID, iat: Math.floor(Date.now() / 1000) };
  const signingInput = `${b64urlStr(JSON.stringify(header))}.${b64urlStr(JSON.stringify(payload))}`;
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${b64url(new Uint8Array(sig))}`;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  if (!TRIGGER_SECRET || req.headers.get("x-webhook-secret") !== TRIGGER_SECRET) {
    return new Response("forbidden", { status: 403 });
  }

  let messageId = "";
  let eventId = "";
  try {
    const body = await req.json();
    messageId = String(body?.message_id ?? "");
    eventId = String(body?.event_id ?? "");
  } catch {
    return new Response("bad_request", { status: 400 });
  }
  if (!messageId && !eventId) return new Response("no_id", { status: 400 });

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  let title = "The League";
  let preview = "";
  let excludeMember: string | null = null;
  let threadId = "league-comms";

  if (eventId) {
    const { data: ev } = await admin
      .from("events")
      .select("id, title, starts_at, created_by, members(display_name)")
      .eq("id", eventId)
      .maybeSingle();
    if (!ev) return new Response("event_not_found", { status: 404 });
    const creator = (ev.members as { display_name?: string } | null)?.display_name ?? "Someone";
    const when = new Date(ev.starts_at as string).toLocaleString("en-US", {
      timeZone: "America/Chicago", weekday: "short", month: "short",
      day: "numeric", hour: "numeric", minute: "2-digit",
    });
    title = "📅 New Event";
    preview = `${ev.title} — ${when} (by ${creator})`.slice(0, 180);
    excludeMember = ev.created_by as string | null;
    threadId = "league-events";
  } else {
    const { data: msg } = await admin
      .from("messages")
      .select("id, body, attachment_kind, member_id, members(display_name)")
      .eq("id", messageId)
      .maybeSingle();
    if (!msg) return new Response("message_not_found", { status: 404 });
    const senderName = (msg.members as { display_name?: string } | null)?.display_name ?? "Someone";
    const bodyText = (msg.body ?? "").trim();
    const kindLabel: Record<string, string> = {
      image: "📷 Photo", gif: "🎬 GIF", video: "🎬 Video", audio: "🎤 Voice message", file: "📎 File",
    };
    title = `${senderName} · The League`;
    preview = bodyText.length ? bodyText.slice(0, 180) : (kindLabel[msg.attachment_kind as string] ?? "New message");
    excludeMember = msg.member_id as string;
  }

  // Everyone else's devices.
  let query = admin.from("device_tokens").select("token");
  if (excludeMember) query = query.neq("member_id", excludeMember);
  const { data: tokens } = await query;
  if (!tokens || tokens.length === 0) return new Response("no_devices", { status: 200 });

  if (!APNS_PRIVATE_KEY || !APNS_KEY_ID || !APNS_TEAM_ID) {
    return new Response("apns_not_configured", { status: 500 });
  }

  const key = await importKey(APNS_PRIVATE_KEY);
  const jwt = await makeProviderToken(key);

  const payload = JSON.stringify({
    aps: {
      alert: { title, body: preview },
      sound: "default",
      badge: 1,
      "thread-id": threadId,
    },
  });

  let sent = 0;
  const stale: string[] = [];
  await Promise.all(tokens.map(async ({ token }) => {
    const res = await fetch(`${APNS_HOST}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": APNS_BUNDLE_ID,
        "apns-push-type": "alert",
        "apns-priority": "10",
      },
      body: payload,
    });
    if (res.status === 200) { sent++; return; }
    // 410 Unregistered or 400 BadDeviceToken => the token is dead, prune it.
    if (res.status === 410) { stale.push(token); return; }
    if (res.status === 400) {
      const reason = await res.text().catch(() => "");
      if (reason.includes("BadDeviceToken")) stale.push(token);
    }
  }));

  // Prune tokens Apple says are gone.
  if (stale.length) await admin.from("device_tokens").delete().in("token", stale);

  return new Response(JSON.stringify({ sent, pruned: stale.length }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});

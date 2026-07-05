// Phone-only login. No verification code — the roster is the allow-list.
// Given a phone number, if it belongs to an active member we mint a Supabase
// session whose JWT carries app_metadata.member_id, which every RLS policy keys off.
//
// Runs with the service role key (auto-injected, never shipped to the app).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Normalize to E.164. US-centric: 10 digits -> +1XXXXXXXXXX; 11 digits starting
// with 1 -> +1...; anything already starting with + is kept.
function normalizePhone(raw: string): string | null {
  if (!raw) return null;
  const trimmed = raw.trim();
  if (trimmed.startsWith("+")) {
    const digits = trimmed.slice(1).replace(/\D/g, "");
    return digits.length >= 8 ? "+" + digits : null;
  }
  const digits = trimmed.replace(/\D/g, "");
  if (digits.length === 10) return "+1" + digits;
  if (digits.length === 11 && digits.startsWith("1")) return "+" + digits;
  return null;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let phoneRaw = "";
  try {
    const body = await req.json();
    phoneRaw = String(body?.phone ?? "");
  } catch {
    return json({ error: "invalid_body" }, 400);
  }

  const phone = normalizePhone(phoneRaw);
  if (!phone) return json({ error: "invalid_phone" }, 400);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // 1. Find the member on the roster.
  const { data: member, error: memberErr } = await admin
    .from("members")
    .select("id, phone, display_name, is_admin, is_trivia_master, is_active, avatar, auth_user_id")
    .eq("phone", phone)
    .maybeSingle();

  if (memberErr) return json({ error: "lookup_failed", detail: memberErr.message }, 500);
  if (!member) return json({ error: "not_on_roster" }, 403);
  if (!member.is_active) return json({ error: "inactive" }, 403);

  // Synthetic email used only to anchor the Supabase auth user to this member.
  const email = `${member.id}@members.justiceleagueok.com`;

  // 2. Ensure a matching auth user exists, carrying member_id in app_metadata.
  let authUserId = member.auth_user_id as string | null;
  if (!authUserId) {
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      email_confirm: true,
      app_metadata: { member_id: member.id },
    });
    if (createErr || !created?.user) {
      return json({ error: "create_user_failed", detail: createErr?.message }, 500);
    }
    authUserId = created.user.id;
    await admin.from("members").update({ auth_user_id: authUserId }).eq("id", member.id);
  } else {
    // Keep app_metadata fresh in case it was ever cleared.
    await admin.auth.admin.updateUserById(authUserId, {
      app_metadata: { member_id: member.id },
    });
  }

  // 3. Mint a session by generating a magic-link OTP and verifying it server-side.
  const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email,
  });
  if (linkErr || !link?.properties?.email_otp) {
    return json({ error: "link_failed", detail: linkErr?.message }, 500);
  }

  const anon = createClient(SUPABASE_URL, ANON_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: verified, error: verifyErr } = await anon.auth.verifyOtp({
    email,
    token: link.properties.email_otp,
    type: "email",
  });
  if (verifyErr || !verified?.session) {
    return json({ error: "verify_failed", detail: verifyErr?.message }, 500);
  }

  return json({
    access_token: verified.session.access_token,
    refresh_token: verified.session.refresh_token,
    member: {
      id: member.id,
      phone: member.phone,
      display_name: member.display_name,
      is_admin: member.is_admin,
      is_trivia_master: member.is_trivia_master,
      is_active: member.is_active,
      avatar: member.avatar,
    },
  });
});

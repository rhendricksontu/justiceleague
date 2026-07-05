-- Push notifications for new chat messages.
-- Device tokens are registered by the app after the user grants permission;
-- an INSERT trigger on messages calls the `send-push` edge function, which
-- fans the alert out to every other member's devices via APNs.

create table if not exists public.device_tokens (
  token       text primary key,                                   -- APNs device token (hex)
  member_id   uuid not null references public.members(id) on delete cascade,
  platform    text not null default 'ios',
  updated_at  timestamptz not null default now()
);

create index if not exists idx_device_tokens_member on public.device_tokens (member_id);

alter table public.device_tokens enable row level security;

-- A member can see their own registered devices; writes go through the RPC.
create policy device_tokens_select_own on public.device_tokens
  for select to authenticated
  using (member_id = public.current_member_id());

grant select on public.device_tokens to authenticated;

-- Register (or re-point) a device token to the current member.
create or replace function public.register_device_token(p_token text, p_platform text default 'ios')
returns void language plpgsql security definer set search_path = public
as $$
begin
  if public.current_member_id() is null then raise exception 'not authenticated'; end if;
  if p_token is null or length(p_token) = 0 then return; end if;
  insert into public.device_tokens (token, member_id, platform, updated_at)
  values (p_token, public.current_member_id(), coalesce(p_platform, 'ios'), now())
  on conflict (token) do update
    set member_id = excluded.member_id,
        platform  = excluded.platform,
        updated_at = now();
end;
$$;

grant execute on function public.register_device_token(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- On new message, ping the send-push edge function (fire-and-forget via pg_net).
-- ---------------------------------------------------------------------------
create extension if not exists pg_net;

create or replace function public.notify_new_message()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://lwapoxbgtfutugdeudgb.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx3YXBveGJndGZ1dHVnZGV1ZGdiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNzUxNTAsImV4cCI6MjA5ODg1MTE1MH0.yUYHKItYH_oiknkr87KzpLw_PxNROsoZ78IbIl6bZI8',
      'x-webhook-secret', '9fa5014faf2228f972553b4a365b28279e766b688f146718'
    ),
    body := jsonb_build_object('message_id', NEW.id)
  );
  return NEW;
end;
$$;

drop trigger if exists on_message_created on public.messages;
create trigger on_message_created
  after insert on public.messages
  for each row execute function public.notify_new_message();

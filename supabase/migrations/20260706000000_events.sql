-- Group calendar: events + RSVPs. Anyone can create an event; RSVPs are
-- per-occurrence (so recurring events can be answered week by week).

create table if not exists public.events (
  id               uuid primary key default gen_random_uuid(),
  created_by       uuid references public.members(id) on delete set null,
  title            text not null check (char_length(title) between 1 and 200),
  description      text,
  starts_at        timestamptz not null,
  ends_at          timestamptz not null,
  recurrence       text not null default 'none'
                     check (recurrence in ('none', 'daily', 'weekly', 'biweekly', 'monthly')),
  recurrence_until date,
  created_at       timestamptz not null default now()
);

create index if not exists idx_events_starts_at on public.events (starts_at);

create table if not exists public.event_rsvps (
  event_id   uuid not null references public.events(id) on delete cascade,
  member_id  uuid not null references public.members(id) on delete cascade,
  occurrence date not null,            -- the specific instance's date (Central)
  status     text not null check (status in ('yes', 'no', 'maybe')),
  updated_at timestamptz not null default now(),
  primary key (event_id, member_id, occurrence)
);

alter table public.events enable row level security;
alter table public.event_rsvps enable row level security;

-- events: every member reads; anyone creates their own; creator or admin edits/deletes.
create policy events_select on public.events
  for select to authenticated using (public.current_member_id() is not null);
create policy events_insert on public.events
  for insert to authenticated with check (created_by = public.current_member_id());
create policy events_update on public.events
  for update to authenticated
  using (created_by = public.current_member_id() or public.is_admin())
  with check (created_by = public.current_member_id() or public.is_admin());
create policy events_delete on public.events
  for delete to authenticated
  using (created_by = public.current_member_id() or public.is_admin());

-- rsvps: everyone reads; you manage only your own.
create policy rsvps_select on public.event_rsvps
  for select to authenticated using (public.current_member_id() is not null);
create policy rsvps_insert on public.event_rsvps
  for insert to authenticated with check (member_id = public.current_member_id());
create policy rsvps_update on public.event_rsvps
  for update to authenticated using (member_id = public.current_member_id()) with check (member_id = public.current_member_id());
create policy rsvps_delete on public.event_rsvps
  for delete to authenticated using (member_id = public.current_member_id());

grant select, insert, update, delete on public.events to authenticated;
grant select, insert, update, delete on public.event_rsvps to authenticated;

alter publication supabase_realtime add table public.events;
alter publication supabase_realtime add table public.event_rsvps;

-- Notify the group when a new event is created (reuses the send-push function).
create or replace function public.notify_new_event()
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
    body := jsonb_build_object('event_id', NEW.id)
  );
  return NEW;
end;
$$;

drop trigger if exists on_event_created on public.events;
create trigger on_event_created
  after insert on public.events
  for each row execute function public.notify_new_event();

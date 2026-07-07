-- Moderation for App Store UGC compliance: block a member and report a message.

create table if not exists public.blocked_members (
  blocker_id uuid not null references public.members(id) on delete cascade,
  blocked_id uuid not null references public.members(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);
alter table public.blocked_members enable row level security;
create policy blocked_select_own on public.blocked_members
  for select to authenticated using (blocker_id = public.current_member_id());
create policy blocked_insert_own on public.blocked_members
  for insert to authenticated with check (blocker_id = public.current_member_id());
create policy blocked_delete_own on public.blocked_members
  for delete to authenticated using (blocker_id = public.current_member_id());
grant select, insert, delete on public.blocked_members to authenticated;

create table if not exists public.message_reports (
  id          uuid primary key default gen_random_uuid(),
  message_id  uuid not null references public.messages(id) on delete cascade,
  reporter_id uuid not null references public.members(id) on delete cascade,
  reason      text,
  created_at  timestamptz not null default now()
);
alter table public.message_reports enable row level security;
-- Anyone can file a report for themselves; admins review them.
create policy reports_insert_own on public.message_reports
  for insert to authenticated with check (reporter_id = public.current_member_id());
create policy reports_select_admin on public.message_reports
  for select to authenticated using (public.is_admin());
grant select, insert on public.message_reports to authenticated;

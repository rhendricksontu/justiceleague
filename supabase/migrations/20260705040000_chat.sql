-- Group chat — one shared channel for the whole Justice League.
-- Every active member can read every message and post their own.

create table if not exists public.messages (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references public.members(id) on delete cascade,
  body        text not null check (char_length(body) between 1 and 4000),
  created_at  timestamptz not null default now()
);

create index if not exists idx_messages_created_at on public.messages (created_at);

-- Per-member "last read" marker drives the unread badge.
alter table public.members add column if not exists chat_last_read_at timestamptz;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
alter table public.messages enable row level security;

-- Any signed-in member can read the whole channel.
create policy messages_select on public.messages
  for select to authenticated
  using (public.current_member_id() is not null);

-- You may post only as yourself.
create policy messages_insert on public.messages
  for insert to authenticated
  with check (member_id = public.current_member_id());

-- You may delete your own message (long-press to remove).
create policy messages_delete_own on public.messages
  for delete to authenticated
  using (member_id = public.current_member_id());

grant select, insert, delete on public.messages to authenticated;

-- ---------------------------------------------------------------------------
-- Unread helpers (SECURITY DEFINER, scoped to the caller)
-- ---------------------------------------------------------------------------

-- Mark the channel read up to now for the current member.
create or replace function public.mark_chat_read()
returns void language plpgsql security definer set search_path = public
as $$
begin
  if public.current_member_id() is null then raise exception 'not authenticated'; end if;
  update public.members set chat_last_read_at = now() where id = public.current_member_id();
end;
$$;

grant execute on function public.mark_chat_read() to authenticated;

-- How many messages (from others) have arrived since the caller last read.
create or replace function public.chat_unread_count()
returns integer language sql stable security definer set search_path = public
as $$
  select count(*)::int
  from public.messages msg
  where msg.member_id <> public.current_member_id()
    and msg.created_at > coalesce(
      (select chat_last_read_at from public.members where id = public.current_member_id()),
      'epoch'::timestamptz
    )
$$;

grant execute on function public.chat_unread_count() to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime: broadcast row changes on the messages table.
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.messages;

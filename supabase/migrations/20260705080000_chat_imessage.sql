-- iMessage-style chat: tapback reactions, replies, edits.

-- Reply + edit metadata on messages.
alter table public.messages add column if not exists reply_to uuid references public.messages(id) on delete set null;
alter table public.messages add column if not exists edited_at timestamptz;

-- Let a member edit their own message (text/edited_at).
drop policy if exists messages_update_own on public.messages;
create policy messages_update_own on public.messages
  for update to authenticated
  using (member_id = public.current_member_id())
  with check (member_id = public.current_member_id());

-- Tapback reactions — one per member per message (changing replaces it).
create table if not exists public.message_reactions (
  message_id uuid not null references public.messages(id) on delete cascade,
  member_id  uuid not null references public.members(id) on delete cascade,
  emoji      text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, member_id)
);

alter table public.message_reactions enable row level security;

create policy reactions_select on public.message_reactions
  for select to authenticated using (public.current_member_id() is not null);
create policy reactions_insert_own on public.message_reactions
  for insert to authenticated with check (member_id = public.current_member_id());
create policy reactions_update_own on public.message_reactions
  for update to authenticated using (member_id = public.current_member_id()) with check (member_id = public.current_member_id());
create policy reactions_delete_own on public.message_reactions
  for delete to authenticated using (member_id = public.current_member_id());

grant select, insert, update, delete on public.message_reactions to authenticated;

alter publication supabase_realtime add table public.message_reactions;

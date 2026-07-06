-- Broadcast member row changes (used for live read receipts in chat).
alter publication supabase_realtime add table public.members;

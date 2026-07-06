-- Image attachments for group chat (iMessage-style photos/camera).
-- A message may now carry an image (in the chat-media storage bucket) with an
-- optional text caption.

alter table public.messages add column if not exists image_path text;

-- Body was required + non-empty; allow image-only messages now.
alter table public.messages alter column body drop not null;
alter table public.messages drop constraint if exists messages_body_check;
alter table public.messages add constraint messages_content_check check (
  (body is null or char_length(body) <= 4000)
  and (coalesce(char_length(body), 0) > 0 or image_path is not null)
);

-- ---------------------------------------------------------------------------
-- Private storage bucket for chat images.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('chat-media', 'chat-media', false)
on conflict (id) do nothing;

-- Any signed-in member can read + upload; you can delete your own uploads.
drop policy if exists chat_media_select on storage.objects;
create policy chat_media_select on storage.objects
  for select to authenticated
  using (bucket_id = 'chat-media' and public.current_member_id() is not null);

drop policy if exists chat_media_insert on storage.objects;
create policy chat_media_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'chat-media' and public.current_member_id() is not null);

drop policy if exists chat_media_delete on storage.objects;
create policy chat_media_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'chat-media' and owner = auth.uid());

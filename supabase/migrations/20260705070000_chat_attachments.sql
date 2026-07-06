-- Generalize chat attachments beyond images: photos, gifs, videos, files.
-- Replaces the single image_path column with a typed attachment.

alter table public.messages add column if not exists attachment_path text;
alter table public.messages add column if not exists attachment_kind text;  -- image | gif | video | file
alter table public.messages add column if not exists attachment_name text;  -- original filename (files)
alter table public.messages add column if not exists attachment_mime text;

-- Carry any existing image messages over to the new shape.
update public.messages
   set attachment_path = image_path, attachment_kind = 'image', attachment_mime = 'image/jpeg'
 where image_path is not null and attachment_path is null;

alter table public.messages drop column if exists image_path;

-- A message must have text or an attachment.
alter table public.messages drop constraint if exists messages_content_check;
alter table public.messages add constraint messages_content_check check (
  (body is null or char_length(body) <= 4000)
  and (coalesce(char_length(body), 0) > 0 or attachment_path is not null)
);

alter table public.messages drop constraint if exists messages_attachment_kind_check;
alter table public.messages add constraint messages_attachment_kind_check check (
  attachment_kind is null or attachment_kind in ('image', 'gif', 'video', 'file')
);

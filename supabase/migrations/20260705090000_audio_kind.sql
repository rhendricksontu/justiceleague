-- Allow voice-message attachments.
alter table public.messages drop constraint if exists messages_attachment_kind_check;
alter table public.messages add constraint messages_attachment_kind_check check (
  attachment_kind is null or attachment_kind in ('image', 'gif', 'video', 'audio', 'file')
);

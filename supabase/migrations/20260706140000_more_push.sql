-- Additional push notifications: new trivia, trivia revealed, event updated.

-- Shared helper so triggers don't each repeat the URL / auth / secret.
create or replace function public.ping_push(payload jsonb)
returns void language plpgsql security definer set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://lwapoxbgtfutugdeudgb.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imx3YXBveGJndGZ1dHVnZGV1ZGdiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyNzUxNTAsImV4cCI6MjA5ODg1MTE1MH0.yUYHKItYH_oiknkr87KzpLw_PxNROsoZ78IbIl6bZI8',
      'x-webhook-secret', '9fa5014faf2228f972553b4a365b28279e766b688f146718'
    ),
    body := payload
  );
end;
$$;

-- New trivia question posted.
create or replace function public.notify_new_trivia()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public.ping_push(jsonb_build_object('question_id', NEW.id, 'kind', 'new'));
  return NEW;
end;
$$;
drop trigger if exists on_trivia_created on public.trivia_questions;
create trigger on_trivia_created
  after insert on public.trivia_questions
  for each row execute function public.notify_new_trivia();

-- Trivia answers revealed (revealed flips false -> true).
create or replace function public.notify_trivia_revealed()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public.ping_push(jsonb_build_object('question_id', NEW.id, 'kind', 'revealed'));
  return NEW;
end;
$$;
drop trigger if exists on_trivia_revealed on public.trivia_questions;
create trigger on_trivia_revealed
  after update on public.trivia_questions
  for each row
  when (old.revealed is distinct from new.revealed and new.revealed)
  execute function public.notify_trivia_revealed();

-- Existing event was edited (time / location / notes changed).
create or replace function public.notify_event_updated()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public.ping_push(jsonb_build_object('event_id', NEW.id, 'kind', 'updated'));
  return NEW;
end;
$$;
drop trigger if exists on_event_updated on public.events;
create trigger on_event_updated
  after update on public.events
  for each row execute function public.notify_event_updated();

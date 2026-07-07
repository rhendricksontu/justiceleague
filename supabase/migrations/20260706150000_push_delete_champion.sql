-- Push for event cancellation and champion crowning.

-- Event deleted / cancelled. The row is gone by the time the push is built, so
-- pass the details from OLD in the payload.
create or replace function public.notify_event_deleted()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public.ping_push(jsonb_build_object(
    'kind', 'deleted',
    'event_title', OLD.title,
    'starts_at', OLD.starts_at,
    'ends_at', OLD.ends_at
  ));
  return OLD;
end;
$$;
drop trigger if exists on_event_deleted on public.events;
create trigger on_event_deleted
  after delete on public.events
  for each row execute function public.notify_event_deleted();

-- Champion crowned. Fires immediately when an admin records a champion in the
-- Hall of Fame, and monthly (below) for auto-computed months.
create or replace function public.notify_champion_crowned()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public.ping_push(jsonb_build_object('champion_month', NEW.month::text));
  return NEW;
end;
$$;
drop trigger if exists on_champion_crowned on public.hall_of_fame;
create trigger on_champion_crowned
  after insert on public.hall_of_fame
  for each row execute function public.notify_champion_crowned();

-- On the 1st of each month, crown the just-ended month's champion(s).
create extension if not exists pg_cron;
do $$
begin
  perform cron.unschedule('crown-monthly-champion');
exception when others then null;
end $$;
select cron.schedule(
  'crown-monthly-champion',
  '0 13 1 * *',   -- 1st of month, 13:00 UTC (~8am Central)
  $cmd$
    select public.ping_push(jsonb_build_object(
      'champion_month',
      (date_trunc('month', (now() at time zone 'America/Chicago')) - interval '1 month')::date::text
    ));
  $cmd$
);

-- Optional location for calendar events.
alter table public.events add column if not exists location text;

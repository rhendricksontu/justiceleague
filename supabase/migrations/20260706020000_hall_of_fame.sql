-- Manual / retroactive Hall of Fame champions.
--
-- v_monthly_winners is otherwise computed purely from graded trivia responses,
-- so months that happened before the app existed (or were run over text) can't
-- be crowned automatically. This table lets admins record a champion for a
-- given month; those entries take precedence over the computed winner.

create table if not exists public.hall_of_fame (
  id            uuid primary key default gen_random_uuid(),
  month         date not null unique,
  member_id     uuid not null references public.members(id) on delete cascade,
  correct_count int,                       -- optional; null when the tally is unknown
  created_at    timestamptz not null default now(),
  constraint hall_of_fame_month_is_first check (month = date_trunc('month', month)::date)
);

alter table public.hall_of_fame enable row level security;

create policy hall_of_fame_select on public.hall_of_fame
  for select to authenticated using (true);
create policy hall_of_fame_admin_write on public.hall_of_fame
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

grant select, insert, update, delete on public.hall_of_fame to authenticated;

-- Prefer manual champions per month; fall back to the computed winner otherwise.
create or replace view public.v_monthly_winners
with (security_invoker = true) as
  select
    h.month,
    h.member_id,
    m.display_name,
    h.correct_count
  from public.hall_of_fame h
  join public.members m on m.id = h.member_id
  union all
  select
    w.month, w.member_id, w.display_name, w.correct_count
  from (
    select
      s.*,
      rank() over (partition by s.month order by s.correct_count desc) as rnk
    from public.v_monthly_scores s
    where s.correct_count > 0
  ) w
  where w.rnk = 1
    and not exists (select 1 from public.hall_of_fame h2 where h2.month = w.month);

grant select on public.v_monthly_winners to authenticated;

-- Crown Cale Gee for June 2026 (tally unknown — recorded over text pre-app).
insert into public.hall_of_fame (month, member_id, correct_count)
select date '2026-06-01', m.id, null
from public.members m
where m.display_name = 'Cale Gee'
order by m.created_at
limit 1
on conflict (month) do update set member_id = excluded.member_id;

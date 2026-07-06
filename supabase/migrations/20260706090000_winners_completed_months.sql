-- Only crown auto-computed champions for COMPLETED months. The current,
-- in-progress month shouldn't have a champion yet (the app shows it as
-- "In Progress"). Manual hall_of_fame entries are unaffected.
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
    and w.month < date_trunc('month', (now() at time zone 'America/Chicago'))::date
    and not exists (select 1 from public.hall_of_fame h2 where h2.month = w.month);

grant select on public.v_monthly_winners to authenticated;

-- Trivia master scoring: when no participant answers a question correctly, the
-- master who posted it earns the point.
--
-- The retroactive July questions were entered under Ryan for convenience, but
-- Ryan answered them as a participant, so the real poster is the master, Andy
-- Campbell. Re-attribute them, then teach the scoring view about master wins.

-- 1. The posting master owns the question.
update public.trivia_questions q
set created_by = m.id
from public.members m
where m.display_name = 'Andy Campbell'
  and q.question_date in (date '2026-07-01', date '2026-07-02', date '2026-07-03');

-- 2. Monthly scores = correct answers PLUS master wins. A master win is a
--    revealed, fully-graded question that had at least one answer and none
--    correct — the creator (the master) earns 1 point for it.
create or replace view public.v_monthly_scores
with (security_invoker = true) as
  with graded as (
    select
      r.member_id,
      date_trunc('month', q.question_date)::date as month,
      count(*) filter (where r.is_correct)              as correct_count,
      count(r.id) filter (where r.is_correct is not null) as graded_count
    from public.trivia_responses r
    join public.trivia_questions q on q.id = r.question_id
    group by r.member_id, date_trunc('month', q.question_date)
  ),
  master_wins as (
    select
      q.created_by as member_id,
      date_trunc('month', q.question_date)::date as month,
      count(*) as correct_count
    from public.trivia_questions q
    where q.revealed
      and exists (
        select 1 from public.trivia_responses r
        where r.question_id = q.id and r.is_correct is not null)
      and not exists (
        select 1 from public.trivia_responses r
        where r.question_id = q.id and r.is_correct is null)
      and not exists (
        select 1 from public.trivia_responses r
        where r.question_id = q.id and r.is_correct is true)
    group by q.created_by, date_trunc('month', q.question_date)
  ),
  combined as (
    select member_id, month, correct_count, graded_count from graded
    union all
    select member_id, month, correct_count, 0 as graded_count from master_wins
  )
  select
    m.id            as member_id,
    m.display_name,
    c.month,
    sum(c.correct_count)::bigint as correct_count,
    sum(c.graded_count)::bigint  as graded_count
  from combined c
  join public.members m on m.id = c.member_id
  group by m.id, m.display_name, c.month;

grant select on public.v_monthly_scores to authenticated;

-- Retroactive July 1, 2026 trivia: question, answer key, and graded responses.
-- Ryan is correct (Thomas Paine); everyone else answered Franklin and is wrong.

-- Question, created by Ryan and already revealed.
insert into public.trivia_questions (question_date, prompt, created_by, revealed, revealed_at)
select date '2026-07-01',
       'This man, writing as "Republicus" in the Pennsylvania Evening Post on June 29, 1776, made what is believed to be the first public declaration calling for the country to be named the "United States of America".',
       m.id, true, timestamptz '2026-07-01 20:00:00-05'
from public.members m
where m.display_name = 'Ryan Hendrickson'
order by m.created_at
limit 1
on conflict (question_date)
  do update set prompt = excluded.prompt, revealed = true, revealed_at = excluded.revealed_at;

-- Answer key.
insert into public.trivia_answer_keys (question_id, correct_answer)
select id, 'Thomas Paine'
from public.trivia_questions
where question_date = date '2026-07-01'
on conflict (question_id) do update set correct_answer = excluded.correct_answer;

-- Each member's answer, already graded.
insert into public.trivia_responses (question_id, member_id, answer, is_correct, submitted_at, graded_at)
select (select id from public.trivia_questions where question_date = date '2026-07-01'),
       m.id, v.answer, v.is_correct,
       timestamptz '2026-07-01 12:00:00-05', timestamptz '2026-07-01 20:00:00-05'
from (values
  ('Ryan Hendrickson', 'Thomas Paine',      true),
  ('Troy Dee',         'Benjamin Franklin', false),
  ('Cale Gee',         'Franklin',          false),
  ('Dave Smith',       'Franklin',          false),
  ('Mark Anderson',    'Franklin',          false),
  ('Mark Walraven',    'Franklin',          false)
) as v(name, answer, is_correct)
join public.members m on m.display_name = v.name
on conflict (question_id, member_id)
  do update set answer = excluded.answer, is_correct = excluded.is_correct, graded_at = excluded.graded_at;

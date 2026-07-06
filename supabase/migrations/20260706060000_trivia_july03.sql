-- Retroactive July 3, 2026 trivia: question, answer key, and graded responses.
-- Gettysburg cavalry question; answer George Armstrong Custard. Everyone
-- guessed Buford, so no one is correct.

-- Question, created by Ryan and already revealed.
insert into public.trivia_questions (question_date, prompt, created_by, revealed, revealed_at)
select date '2026-07-03',
       'On this day, July 3, 1863, this newly promoted brigadier general may have saved the war for the Union by preventing Jeb Stuart''s cavalry from reaching the rear of the Army of the Potomac during the battle of Gettysburg.',
       m.id, true, timestamptz '2026-07-03 20:00:00-05'
from public.members m
where m.display_name = 'Ryan Hendrickson'
order by m.created_at
limit 1
on conflict (question_date)
  do update set prompt = excluded.prompt, revealed = true, revealed_at = excluded.revealed_at;

-- Answer key.
insert into public.trivia_answer_keys (question_id, correct_answer)
select id, 'George Armstrong Custard'
from public.trivia_questions
where question_date = date '2026-07-03'
on conflict (question_id) do update set correct_answer = excluded.correct_answer;

-- Each member's answer, already graded (all wrong — everyone said Buford).
insert into public.trivia_responses (question_id, member_id, answer, is_correct, submitted_at, graded_at)
select (select id from public.trivia_questions where question_date = date '2026-07-03'),
       m.id, v.answer, v.is_correct,
       timestamptz '2026-07-03 12:00:00-05', timestamptz '2026-07-03 20:00:00-05'
from (values
  ('Dave Smith',       'Buford',      false),
  ('Troy Dee',         'Buford',      false),
  ('Cale Gee',         'John Buford', false),
  ('Mark Walraven',    'Buford',      false),
  ('Ryan Hendrickson', 'Buford',      false),
  ('Mark Anderson',    'Buford',      false)
) as v(name, answer, is_correct)
join public.members m on m.display_name = v.name
on conflict (question_id, member_id)
  do update set answer = excluded.answer, is_correct = excluded.is_correct, graded_at = excluded.graded_at;

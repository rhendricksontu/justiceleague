-- Retroactive July 5, 2026 trivia. Answer Seattle Seahawks. Ryan and Cale
-- correct; the rest wrong. Posted by the trivia master, Andy Campbell.

-- Question, created by the master and already revealed.
insert into public.trivia_questions (question_date, prompt, created_by, revealed, revealed_at)
select date '2026-07-05',
       'Name the team for which Jerry Rice played the last 11 games of his NFL career.',
       m.id, true, timestamptz '2026-07-05 20:00:00-05'
from public.members m
where m.display_name = 'Andy Campbell'
order by m.created_at
limit 1
on conflict (question_date)
  do update set prompt = excluded.prompt, created_by = excluded.created_by,
                revealed = true, revealed_at = excluded.revealed_at;

-- Answer key.
insert into public.trivia_answer_keys (question_id, correct_answer)
select id, 'Seattle Seahawks'
from public.trivia_questions
where question_date = date '2026-07-05'
on conflict (question_id) do update set correct_answer = excluded.correct_answer;

-- Each member's answer, already graded.
insert into public.trivia_responses (question_id, member_id, answer, is_correct, submitted_at, graded_at)
select (select id from public.trivia_questions where question_date = date '2026-07-05'),
       m.id, v.answer, v.is_correct,
       timestamptz '2026-07-05 12:00:00-05', timestamptz '2026-07-05 20:00:00-05'
from (values
  ('Ryan Hendrickson', 'Seattle Seahawks',   true),
  ('Mark Walraven',    'Kansas City Chiefs',  false),
  ('Dave Smith',       'Raiders',             false),
  ('Cale Gee',         'Seahawks',            true),
  ('Troy Dee',         'Raiders',             false),
  ('Mark Anderson',    'Raiders',             false)
) as v(name, answer, is_correct)
join public.members m on m.display_name = v.name
on conflict (question_id, member_id)
  do update set answer = excluded.answer, is_correct = excluded.is_correct, graded_at = excluded.graded_at;

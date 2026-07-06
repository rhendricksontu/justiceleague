-- Retroactive July 4, 2026 trivia: two-part Independence Day question. Answer
-- is "1) Exotic Dancer 2) Dolphin". Everyone answered correctly. Posted by the
-- trivia master, Andy Campbell.

-- Question, created by the master and already revealed.
insert into public.trivia_questions (question_date, prompt, created_by, revealed, revealed_at)
select date '2026-07-04',
       'Because this is a holiday, you get a two question trivia. And because today is July 4, what else could I ask about other than the greatest July 4 movie of all time, Independence Day?

1) Will Smith''s partner in the movie, Jasmine, was played by Vivica A. Fox. What job did Jasmine tell the first lady of the US she did for a living?

2) What animal is featured on the ring Will Smith gives her when he proposed in the movie?',
       m.id, true, timestamptz '2026-07-04 20:00:00-05'
from public.members m
where m.display_name = 'Andy Campbell'
order by m.created_at
limit 1
on conflict (question_date)
  do update set prompt = excluded.prompt, created_by = excluded.created_by,
                revealed = true, revealed_at = excluded.revealed_at;

-- Answer key.
insert into public.trivia_answer_keys (question_id, correct_answer)
select id, '1) Exotic Dancer 2) Dolphin'
from public.trivia_questions
where question_date = date '2026-07-04'
on conflict (question_id) do update set correct_answer = excluded.correct_answer;

-- Each member's answer, all graded correct.
insert into public.trivia_responses (question_id, member_id, answer, is_correct, submitted_at, graded_at)
select (select id from public.trivia_questions where question_date = date '2026-07-04'),
       m.id, v.answer, v.is_correct,
       timestamptz '2026-07-04 12:00:00-05', timestamptz '2026-07-04 20:00:00-05'
from (values
  ('Ryan Hendrickson', '1) Exotic Dancer 2) Dolphin', true),
  ('Dave Smith',       '1) dancer...exotic 2) dolphin', true),
  ('Troy Dee',         '1) Dancer 2) dolphin',       true),
  ('Cale Gee',         '1) Dirty dancer 2) Dolphin',  true),
  ('Mark Walraven',    '1) Exotic Dancer 2) Dolphin', true),
  ('Mark Anderson',    '1) Exotic Dancer 2) Dolphin', true)
) as v(name, answer, is_correct)
join public.members m on m.display_name = v.name
on conflict (question_id, member_id)
  do update set answer = excluded.answer, is_correct = excluded.is_correct, graded_at = excluded.graded_at;

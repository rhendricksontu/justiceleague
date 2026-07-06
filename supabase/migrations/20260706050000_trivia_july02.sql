-- Retroactive July 2, 2026 trivia: question, answer key, and graded responses.
-- Answer is Brazil (#3 country by count of million-plus cities). Only Mark
-- Anderson is correct; everyone else is wrong.

-- Question, created by Ryan and already revealed.
insert into public.trivia_questions (question_date, prompt, created_by, revealed, revealed_at)
select date '2026-07-02',
       'Ranking countries that have the most cities with a population of more than a million people. #1 is China. China has approximately 130 cities with a population of more than a million people.

The #2 country behind China, a country I will not name, has considerably less cities with a pop of more than 1 million.

Your job today is to guess the #3 country. So the question is, which country ranks third for most cities over a million people?

(You''re not naming the #2 country, just #3.)',
       m.id, true, timestamptz '2026-07-02 20:00:00-05'
from public.members m
where m.display_name = 'Ryan Hendrickson'
order by m.created_at
limit 1
on conflict (question_date)
  do update set prompt = excluded.prompt, revealed = true, revealed_at = excluded.revealed_at;

-- Answer key.
insert into public.trivia_answer_keys (question_id, correct_answer)
select id, 'Brazil'
from public.trivia_questions
where question_date = date '2026-07-02'
on conflict (question_id) do update set correct_answer = excluded.correct_answer;

-- Each member's answer, already graded.
insert into public.trivia_responses (question_id, member_id, answer, is_correct, submitted_at, graded_at)
select (select id from public.trivia_questions where question_date = date '2026-07-02'),
       m.id, v.answer, v.is_correct,
       timestamptz '2026-07-02 12:00:00-05', timestamptz '2026-07-02 20:00:00-05'
from (values
  ('Ryan Hendrickson', 'USA',                          false),
  ('Troy Dee',         'India',                        false),
  ('Cale Gee',         'The United States of America', false),
  ('Mark Walraven',    'The US of A',                  false),
  ('Mark Anderson',    'Brazil',                       true),
  ('Dave Smith',       'USA',                          false)
) as v(name, answer, is_correct)
join public.members m on m.display_name = v.name
on conflict (question_id, member_id)
  do update set answer = excluded.answer, is_correct = excluded.is_correct, graded_at = excluded.graded_at;

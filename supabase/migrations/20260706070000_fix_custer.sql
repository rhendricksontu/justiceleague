-- Fix the July 3 answer-key spelling: Custard -> Custer.
update public.trivia_answer_keys
set correct_answer = 'George Armstrong Custer'
where question_id = (select id from public.trivia_questions where question_date = date '2026-07-03');

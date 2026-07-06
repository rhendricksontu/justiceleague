-- Grading lock for trivia days.
--
-- grading_locked is a nullable override:
--   null  = automatic (locked once the question's day has ended)
--   true  = master locked it manually
--   false = master unlocked it manually
-- The app computes the effective lock from this plus the date, and lets the
-- master toggle it. Locked => read-only "View Responses"; unlocked => grading.
alter table public.trivia_questions
  add column if not exists grading_locked boolean;

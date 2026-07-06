-- Grading lock is now derived from the date in the app (previous days locked,
-- current day unlocked) with a session-local override, so the persisted column
-- is no longer used.
alter table public.trivia_questions
  drop column if exists grading_locked;

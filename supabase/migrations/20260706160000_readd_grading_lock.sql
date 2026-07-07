-- Persisted grading-lock override so a manual lock on the current day survives
-- navigation. null = automatic (current day unlocked, past days locked); the
-- master locking/unlocking the current day writes true/false here. Past days
-- still always open locked in the app regardless of this value.
alter table public.trivia_questions
  add column if not exists grading_locked boolean;

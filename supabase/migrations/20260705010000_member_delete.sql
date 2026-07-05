-- Allow deleting a member even if they authored trivia questions: keep the
-- question but null out its author (instead of blocking the delete via FK).
alter table public.trivia_questions alter column created_by drop not null;

alter table public.trivia_questions
  drop constraint if exists trivia_questions_created_by_fkey;

alter table public.trivia_questions
  add constraint trivia_questions_created_by_fkey
  foreign key (created_by) references public.members(id) on delete set null;

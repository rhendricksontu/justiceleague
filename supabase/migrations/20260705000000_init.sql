-- Justice League OK — initial schema
-- Daily trivia for a men's group. Phone-only auth via the `login` edge function,
-- which sets app_metadata.member_id on the auth user. All authorization is enforced
-- here with RLS so the app can safely use the public anon key.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.members (
  id            uuid primary key default gen_random_uuid(),
  phone         text not null unique,           -- E.164, e.g. +14055550123
  display_name  text not null,
  is_admin      boolean not null default false,
  is_trivia_master boolean not null default false,
  is_active     boolean not null default true,
  auth_user_id  uuid unique,                    -- linked lazily on first login
  created_at    timestamptz not null default now()
);

-- One trivia question per calendar day (Central Time). The correct answer lives in
-- a separate table so RLS can hide it until reveal.
create table if not exists public.trivia_questions (
  id            uuid primary key default gen_random_uuid(),
  question_date date not null unique,
  prompt        text not null,
  created_by    uuid not null references public.members(id),
  revealed      boolean not null default false,
  revealed_at   timestamptz,
  created_at    timestamptz not null default now()
);

create table if not exists public.trivia_answer_keys (
  question_id     uuid primary key references public.trivia_questions(id) on delete cascade,
  correct_answer  text not null
);

create table if not exists public.trivia_responses (
  id            uuid primary key default gen_random_uuid(),
  question_id   uuid not null references public.trivia_questions(id) on delete cascade,
  member_id     uuid not null references public.members(id) on delete cascade,
  answer        text not null,
  is_correct    boolean,                        -- null until the master grades it
  submitted_at  timestamptz not null default now(),
  graded_at     timestamptz,
  unique (question_id, member_id)
);

create index if not exists idx_responses_question on public.trivia_responses(question_id);
create index if not exists idx_responses_member on public.trivia_responses(member_id);

-- ---------------------------------------------------------------------------
-- Helper functions (SECURITY DEFINER so they can read members without recursing
-- into RLS). member_id comes from the JWT app_metadata set at login.
-- ---------------------------------------------------------------------------

create or replace function public.current_member_id()
returns uuid
language sql stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'member_id',
      ''
    ), ''
  )::uuid
$$;

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists(
    select 1 from public.members
    where id = public.current_member_id() and is_admin and is_active
  )
$$;

create or replace function public.is_master()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists(
    select 1 from public.members
    where id = public.current_member_id() and is_trivia_master and is_active
  )
$$;

-- Is a given question revealed? SECURITY DEFINER to avoid RLS recursion when
-- referenced from other tables' policies.
create or replace function public.question_revealed(qid uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select coalesce((select revealed from public.trivia_questions where id = qid), false)
$$;

-- Who has answered a question (names + answered flag, NOT the answers). Lets the
-- master and members see submission progress without leaking responses pre-reveal.
create or replace function public.question_participation(qid uuid)
returns table(member_id uuid, display_name text, has_answered boolean)
language sql stable security definer
set search_path = public
as $$
  select
    m.id,
    m.display_name,
    exists(select 1 from public.trivia_responses r
           where r.question_id = qid and r.member_id = m.id)
  from public.members m
  where m.is_active
  order by m.display_name
$$;

grant execute on function public.question_participation(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.members            enable row level security;
alter table public.trivia_questions   enable row level security;
alter table public.trivia_answer_keys enable row level security;
alter table public.trivia_responses   enable row level security;

-- members: every active member can see the roster (names for the leaderboard).
create policy members_select on public.members
  for select to authenticated
  using (public.current_member_id() is not null);

-- Only admins can add / edit / remove members.
create policy members_admin_insert on public.members
  for insert to authenticated with check (public.is_admin());
create policy members_admin_update on public.members
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy members_admin_delete on public.members
  for delete to authenticated using (public.is_admin());

-- trivia_questions: all members can read questions (the prompt, not the answer).
create policy questions_select on public.trivia_questions
  for select to authenticated
  using (public.current_member_id() is not null);

-- Only the trivia master creates / updates (reveal) / deletes questions.
create policy questions_master_insert on public.trivia_questions
  for insert to authenticated with check (public.is_master());
create policy questions_master_update on public.trivia_questions
  for update to authenticated using (public.is_master()) with check (public.is_master());
create policy questions_master_delete on public.trivia_questions
  for delete to authenticated using (public.is_master());

-- answer keys: hidden from members until reveal; the master always sees them.
create policy answerkeys_select on public.trivia_answer_keys
  for select to authenticated
  using (public.is_master() or public.question_revealed(question_id));

create policy answerkeys_master_write on public.trivia_answer_keys
  for insert to authenticated with check (public.is_master());
create policy answerkeys_master_update on public.trivia_answer_keys
  for update to authenticated using (public.is_master()) with check (public.is_master());

-- responses: you always see your own; you see others' only after reveal.
create policy responses_select on public.trivia_responses
  for select to authenticated
  using (
    member_id = public.current_member_id()
    or public.question_revealed(question_id)
  );

-- You may submit only your own answer, only before reveal, only once.
create policy responses_insert on public.trivia_responses
  for insert to authenticated
  with check (
    member_id = public.current_member_id()
    and not public.question_revealed(question_id)
  );

-- You may edit your own answer before reveal; the master grades (any row) after reveal.
create policy responses_update_own on public.trivia_responses
  for update to authenticated
  using (member_id = public.current_member_id() and not public.question_revealed(question_id))
  with check (member_id = public.current_member_id() and not public.question_revealed(question_id));

create policy responses_update_master on public.trivia_responses
  for update to authenticated
  using (public.is_master() and public.question_revealed(question_id))
  with check (public.is_master() and public.question_revealed(question_id));

-- ---------------------------------------------------------------------------
-- Leaderboard views (security_invoker so RLS still applies to the reader)
-- ---------------------------------------------------------------------------

-- Per-member correct counts by month.
create or replace view public.v_monthly_scores
with (security_invoker = true) as
  select
    m.id            as member_id,
    m.display_name,
    date_trunc('month', (q.question_date))::date as month,
    count(*) filter (where r.is_correct) as correct_count,
    count(r.id) filter (where r.is_correct is not null) as graded_count
  from public.members m
  join public.trivia_responses r on r.member_id = m.id
  join public.trivia_questions q on q.id = r.question_id
  group by m.id, m.display_name, date_trunc('month', q.question_date);

grant select on public.v_monthly_scores to authenticated;

-- Monthly winner(s): highest correct_count per month (ties => multiple rows).
create or replace view public.v_monthly_winners
with (security_invoker = true) as
  select month, member_id, display_name, correct_count
  from (
    select
      s.*,
      rank() over (partition by s.month order by s.correct_count desc) as rnk
    from public.v_monthly_scores s
    where s.correct_count > 0
  ) ranked
  where rnk = 1;

grant select on public.v_monthly_winners to authenticated;

-- ---------------------------------------------------------------------------
-- Table grants (RLS still governs row visibility)
-- ---------------------------------------------------------------------------
grant select, insert, update, delete on public.members to authenticated;
grant select, insert, update, delete on public.trivia_questions to authenticated;
grant select, insert, update, delete on public.trivia_answer_keys to authenticated;
grant select, insert, update, delete on public.trivia_responses to authenticated;

-- G.I. Joe avatar selection. Each member may pick one avatar; a partial unique
-- index guarantees no two members share the same one (nulls allowed = unselected).
alter table public.members add column if not exists avatar text;

create unique index if not exists members_avatar_unique
  on public.members (avatar) where avatar is not null;

-- A member sets their own avatar (own row only). The unique index enforces
-- exclusivity; a clash raises unique_violation which the app surfaces.
create or replace function public.set_my_avatar(new_avatar text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_member_id() is null then
    raise exception 'not authenticated';
  end if;
  update public.members set avatar = new_avatar
   where id = public.current_member_id();
end;
$$;

grant execute on function public.set_my_avatar(text) to authenticated;

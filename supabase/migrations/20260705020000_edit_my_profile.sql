-- Let any signed-in member update THEIR OWN name and phone (only). Roles and
-- active status remain admin-managed. SECURITY DEFINER so it can write past the
-- admin-only RLS update policy, but it is scoped to the caller's own row.
create or replace function public.update_my_profile(new_name text, new_phone text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.current_member_id() is null then
    raise exception 'not authenticated';
  end if;
  update public.members
     set display_name = new_name,
         phone = new_phone
   where id = public.current_member_id();
end;
$$;

grant execute on function public.update_my_profile(text, text) to authenticated;

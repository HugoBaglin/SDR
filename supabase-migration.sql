-- SDR Gestion des stocks : comptes + droits + temps réel
-- À exécuter dans Supabase > projet reims-sdr > SQL Editor > Run

create or replace function public.is_editor() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('editeur','admin') from public.profiles where id = auth.uid()), false)
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'admin' from public.profiles where id = auth.uid()), false)
$$;

-- Tout nouveau compte démarre en lecture seule
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, role) values (new.id, new.email, 'lecture')
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Comptes existants : Hugo admin, Olivier éditeur
insert into public.profiles (id, email, role)
select id, email,
  case when email = 'h.baglin@stade-de-reims.com' then 'admin' else 'editeur' end
from auth.users
on conflict (id) do update set role = excluded.role;

drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_update_admin on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
create policy profiles_update_admin on public.profiles for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Données : tous les comptes connectés lisent, éditeurs et admins écrivent
drop policy if exists sdr_data_select on public.sdr_data;
drop policy if exists sdr_data_insert on public.sdr_data;
drop policy if exists sdr_data_update on public.sdr_data;
create policy sdr_data_select on public.sdr_data for select to authenticated using (true);
create policy sdr_data_insert on public.sdr_data for insert to authenticated with check (public.is_editor());
create policy sdr_data_update on public.sdr_data for update to authenticated
  using (public.is_editor()) with check (public.is_editor());

-- Qui a modifié, et quand
alter table public.sdr_data add column if not exists updated_by text;
create or replace function public.sdr_data_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at = now();
  new.updated_by = (select email from public.profiles where id = auth.uid());
  return new;
end $$;
drop trigger if exists sdr_data_touch on public.sdr_data;
create trigger sdr_data_touch before insert or update on public.sdr_data
  for each row execute function public.sdr_data_touch();

-- Temps réel
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='sdr_data') then
    alter publication supabase_realtime add table public.sdr_data;
  end if;
end $$;

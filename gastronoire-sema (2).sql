-- =========================================================
-- GASTRONOIRE – adatbázis séma
-- Másold be a Supabase → SQL Editor → New query mezőbe,
-- majd nyomd meg a RUN gombot. Egyszer kell lefuttatni.
-- =========================================================

-- 1) FELHASZNÁLÓK -------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text unique not null,
  full_name   text,
  role        text not null default 'user',   -- 'user' | 'admin'
  country     text,                           -- ISO országkód, pl. 'HU', 'DE'
  created_at  timestamptz not null default now()
);

-- Országonkénti használat összesítése (zászlós statisztikához)
create or replace view public.country_stats as
  select coalesce(country,'??') as country, count(*)::int as users
    from public.profiles
   group by coalesce(country,'??')
   order by count(*) desc;

-- 2) ELŐFIZETÉSEK -------------------------------------------------
-- csomag típusai: 'free' | 'premium' | 'yearly' | 'lifetime' | 'majom'
--   'lifetime' = öröklicenc, egyszeri fizetés, soha nem jár le
--   'majom'    = a te külön, mindent látó admin csomagod
--   Időtartamok: 'trial7' (7 nap) | 'premium' (1 hó) | 'm3' | 'm6' | 'm9' | 'yearly' (12 hó)
create table if not exists public.subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  plan        text not null default 'free',
  status      text not null default 'active', -- 'active' | 'cancelled'
  amount_paid integer,                        -- Ft-ban, egyszeri vásárlásnál
  months      integer,                        -- hány hónapra szól (7 nap = 0)
  expires_at  timestamptz,                    -- null = soha nem jár le (free/lifetime/majom)
  is_gift     boolean not null default false,  -- ajándékba kapott hozzáférés
  created_at  timestamptz not null default now()
);
create index if not exists subs_user_idx on public.subscriptions(user_id);

-- 3) AJÁNDÉKOZÁS / MELLÉK -----------------------------------------
-- Korlátlan e-mailes meghívások az adminból.
create table if not exists public.invites (
  id           uuid primary key default gen_random_uuid(),
  email        text not null,
  plan         text not null default 'premium', -- milyen csomagot ad ajándékba
  invited_by   uuid references public.profiles(id) on delete set null,
  token        text not null unique default encode(gen_random_bytes(16),'hex'),
  status       text not null default 'pending',  -- 'pending' | 'accepted'
  accepted_by  uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists invites_email_idx on public.invites(email);

-- =========================================================
-- AUTOMATIKUS PROFIL LÉTREHOZÁS REGISZTRÁCIÓKOR
-- =========================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name',''))
  on conflict (id) do nothing;

  -- minden új fiók ingyenes csomaggal indul
  insert into public.subscriptions (user_id, plan, status, expires_at)
  values (new.id, 'free', 'active', null);

  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =========================================================
-- BIZTONSÁGI SZABÁLYOK (Row Level Security)
-- =========================================================
alter table public.profiles      enable row level security;
alter table public.subscriptions enable row level security;
alter table public.invites       enable row level security;

-- segédfüggvény: az aktuális felhasználó admin-e?
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;

-- PROFILES: mindenki látja a sajátját; az admin mindent lát és módosít
drop policy if exists profiles_self_read on public.profiles;
create policy profiles_self_read on public.profiles
  for select using (id = auth.uid() or public.is_admin());

drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles
  for update using (id = auth.uid() or public.is_admin());

drop policy if exists profiles_admin_insert on public.profiles;
create policy profiles_admin_insert on public.profiles
  for insert with check (public.is_admin());

-- SUBSCRIPTIONS: saját előfizetés olvasása; az admin mindent
drop policy if exists subs_read on public.subscriptions;
create policy subs_read on public.subscriptions
  for select using (user_id = auth.uid() or public.is_admin());

drop policy if exists subs_admin_write on public.subscriptions;
create policy subs_admin_write on public.subscriptions
  for all using (public.is_admin()) with check (public.is_admin());

-- INVITES: az admin korlátlanul kezel; a meghívott a saját címére lát rá
drop policy if exists invites_admin_all on public.invites;
create policy invites_admin_all on public.invites
  for all using (public.is_admin()) with check (public.is_admin());

drop policy if exists invites_invitee_read on public.invites;
create policy invites_invitee_read on public.invites
  for select using ( lower(email) = lower(coalesce(auth.jwt() ->> 'email','')) );

-- =========================================================
-- ADMIN BEÁLLÍTÁSA
-- A fiók létrejötte UTÁN futtatandó (regisztrálj az appban
-- ezzel az e-maillel: kekmajomautokozmetika@gmail.com),
-- utána ez a sor adminná teszi:
-- =========================================================
update public.profiles
   set role = 'admin'
 where lower(email) = lower('kekmajomautokozmetika@gmail.com');

-- A te korlátlan "majom" csomagod (soha nem jár le):
insert into public.subscriptions (user_id, plan, status, expires_at)
select id, 'majom', 'active', null
  from public.profiles
 where lower(email) = lower('kekmajomautokozmetika@gmail.com')
   and not exists (
     select 1 from public.subscriptions s
      where s.user_id = profiles.id and s.plan = 'majom'
   );

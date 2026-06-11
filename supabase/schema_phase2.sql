-- Phase 2: admin portal (profiles/roles, accounts, employee roster)
-- Run this in the Supabase SQL Editor AFTER schema.sql (Phase 1) has been applied.

-- Maps an authenticated Supabase Auth user to a role.
-- Lorena's row will have role = 'admin'; employees added in Phase 3 get role = 'employee'.
create table if not exists profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    role text not null check (role in ('admin', 'employee')),
    full_name text,
    created_at timestamptz not null default now()
);

alter table profiles enable row level security;

-- A user can read their own profile (needed so the admin UI can check "am I an admin?")
create policy "profiles_select_own" on profiles
    for select using (auth.uid() = id);


create table if not exists accounts (
    id uuid primary key default gen_random_uuid(),
    created_at timestamptz not null default now(),
    lead_id uuid references leads(id),
    first_name text not null,
    last_name text not null,
    email text,
    phone text,
    address text,
    care_needs jsonb not null default '{}'::jsonb,
    status text not null default 'active' check (status in ('active', 'paused', 'closed'))
);

alter table accounts enable row level security;

create index if not exists accounts_status_idx on accounts (status);


create table if not exists employees (
    id uuid primary key default gen_random_uuid(),
    created_at timestamptz not null default now(),
    auth_user_id uuid references auth.users(id),
    first_name text not null,
    last_name text not null,
    email text not null,
    phone text,
    role text,
    certifications text,
    status text not null default 'active' check (status in ('active', 'inactive'))
);

alter table employees enable row level security;


-- Helper: returns true if the currently-authenticated user is an admin.
create or replace function is_admin()
returns boolean
language sql
security definer
stable
as $$
    select exists (
        select 1 from profiles where id = auth.uid() and role = 'admin'
    );
$$;

-- Admin-only access policies: Lorena (role = 'admin') can fully manage
-- leads, accounts, and the employee roster. Everyone else is locked out
-- (the public site never talks to these tables directly -- only through
-- the Phase 1 serverless function, or the authenticated admin portal).

create policy "leads_admin_all" on leads
    for all using (is_admin()) with check (is_admin());

create policy "accounts_admin_all" on accounts
    for all using (is_admin()) with check (is_admin());

create policy "employees_admin_all" on employees
    for all using (is_admin()) with check (is_admin());

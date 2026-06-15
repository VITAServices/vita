-- VITA Services -- Complete Database Schema
-- Run this ONCE in Supabase SQL Editor:
-- https://supabase.com/dashboard/project/jeubjslsrnccdqjmlmsf/sql/new

-- Step 1: Drop all policies and function first (safe if they do not exist)
drop policy if exists "leads_admin_all"          on leads;
drop policy if exists "accounts_admin_all"        on accounts;
drop policy if exists "employees_admin_all"       on employees;
drop policy if exists "employees_select_own"      on employees;
drop policy if exists "employees_insert_own"      on employees;
drop policy if exists "employees_update_own"      on employees;
drop policy if exists "profiles_select_own"       on profiles;
drop policy if exists "shifts_admin_all"          on shifts;
drop policy if exists "shifts_employee_own"       on shifts;
drop policy if exists "availability_admin_all"    on availability;
drop policy if exists "availability_employee_own" on availability;
drop function if exists is_admin();

-- Step 2: Fix leads table (add missing columns from old schema)
alter table leads add column if not exists status
    text not null default 'new';
alter table leads add column if not exists notified_email boolean not null default false;
alter table leads add column if not exists notified_sms   boolean not null default false;
alter table leads enable row level security;
create index if not exists leads_created_at_idx on leads (created_at desc);
create index if not exists leads_status_idx     on leads (status);

-- Step 3: Create all tables
create table if not exists profiles (
    id         uuid        primary key references auth.users(id) on delete cascade,
    role       text        not null check (role in ('admin', 'employee')),
    full_name  text,
    created_at timestamptz not null default now()
);
alter table profiles enable row level security;

create table if not exists accounts (
    id         uuid        primary key default gen_random_uuid(),
    created_at timestamptz not null default now(),
    lead_id    uuid        references leads(id),
    first_name text        not null,
    last_name  text        not null,
    email      text,
    phone      text,
    address    text,
    care_needs jsonb       not null default '{}'::jsonb,
    status     text        not null default 'active' check (status in ('active', 'paused', 'closed'))
);
alter table accounts enable row level security;
create index if not exists accounts_status_idx on accounts (status);

create table if not exists employees (
    id                uuid        primary key default gen_random_uuid(),
    created_at        timestamptz not null default now(),
    auth_user_id      uuid        unique references auth.users(id) on delete set null,
    first_name        text        not null,
    last_name         text        not null,
    email             text        not null,
    phone             text,
    address           text,
    role              text        default 'caregiver',
    certifications    text,
    emergency_contact text,
    emergency_phone   text,
    status            text        not null default 'active' check (status in ('active', 'inactive'))
);
alter table employees enable row level security;
create index if not exists employees_auth_user_idx on employees (auth_user_id);

create table if not exists shifts (
    id           uuid        primary key default gen_random_uuid(),
    created_at   timestamptz not null default now(),
    employee_id  uuid        not null references auth.users(id) on delete cascade,
    client_name  text        not null,
    service_type text        not null default 'home_care',
    start_at     timestamptz not null,
    end_at       timestamptz not null,
    address      text,
    notes        text,
    status       text        not null default 'scheduled' check (status in ('scheduled', 'completed', 'cancelled'))
);
alter table shifts enable row level security;
create index if not exists shifts_employee_id_idx on shifts (employee_id);
create index if not exists shifts_start_at_idx    on shifts (start_at);

create table if not exists availability (
    id           uuid    primary key default gen_random_uuid(),
    employee_id  uuid    not null references auth.users(id) on delete cascade,
    day_of_week  int     not null check (day_of_week between 0 and 6),
    start_time   time    not null,
    end_time     time    not null,
    unique (employee_id, day_of_week)
);
alter table availability enable row level security;

-- Step 4: Create is_admin() BEFORE any policy uses it
create or replace function is_admin()
returns boolean language sql security definer stable as $$
    select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

-- Step 5: Create all policies
create policy "profiles_select_own" on profiles
    for select using (auth.uid() = id);

create policy "leads_admin_all" on leads
    for all using (is_admin()) with check (is_admin());

create policy "accounts_admin_all" on accounts
    for all using (is_admin()) with check (is_admin());

create policy "employees_admin_all" on employees
    for all using (is_admin()) with check (is_admin());
create policy "employees_select_own" on employees
    for select using (auth.uid() = auth_user_id);
create policy "employees_insert_own" on employees
    for insert with check (auth.uid() = auth_user_id);
create policy "employees_update_own" on employees
    for update using (auth.uid() = auth_user_id) with check (auth.uid() = auth_user_id);

create policy "shifts_admin_all" on shifts
    for all using (is_admin()) with check (is_admin());
create policy "shifts_employee_own" on shifts
    for select using (auth.uid() = employee_id);

create policy "availability_admin_all" on availability
    for all using (is_admin()) with check (is_admin());
create policy "availability_employee_own" on availability
    for all using (auth.uid() = employee_id) with check (auth.uid() = employee_id);

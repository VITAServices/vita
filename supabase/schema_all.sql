-- VITA Services -- COMPLETE Database Schema (phases 1-5)
-- Run this ONCE in a new Supabase SQL query:
-- https://supabase.com/dashboard/project/jeubjslsrnccdqjmlmsf/sql/new
-- It is idempotent: safe on a fresh database OR one with earlier phases applied,
-- and safe to re-run.

-- ============================================================
-- 1) TABLES (created only if missing)
-- ============================================================
create table if not exists leads (
    id             uuid        primary key default gen_random_uuid(),
    created_at     timestamptz not null default now(),
    source         text        not null check (source in ('care_request', 'job_application')),
    first_name     text        not null,
    last_name      text        not null,
    email          text        not null,
    phone          text        not null,
    details        jsonb       not null default '{}'::jsonb,
    status         text        not null default 'new' check (status in ('new', 'contacted', 'converted', 'lost')),
    notified_email boolean     not null default false,
    notified_sms   boolean     not null default false
);

create table if not exists profiles (
    id         uuid        primary key references auth.users(id) on delete cascade,
    role       text        not null check (role in ('admin', 'employee')),
    full_name  text,
    created_at timestamptz not null default now()
);

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

-- shifts.employee_id references EMPLOYEES (a later DO block migrates older
-- databases that still point it at auth.users).
create table if not exists shifts (
    id           uuid        primary key default gen_random_uuid(),
    created_at   timestamptz not null default now(),
    employee_id  uuid        not null references employees(id) on delete cascade,
    client_name  text        not null,
    service_type text        not null default 'home_care',
    start_at     timestamptz not null,
    end_at       timestamptz not null,
    address      text,
    notes        text,
    status            text   not null default 'scheduled' check (status in ('scheduled', 'completed', 'cancelled')),
    employee_response text   not null default 'pending'   check (employee_response in ('pending', 'accepted', 'declined'))
);

create table if not exists availability (
    id           uuid    primary key default gen_random_uuid(),
    employee_id  uuid    not null references auth.users(id) on delete cascade,
    day_of_week  int     not null check (day_of_week between 0 and 6),
    start_time   time    not null,
    end_time     time    not null,
    unique (employee_id, day_of_week)
);

create table if not exists certifications (
    id          uuid        primary key default gen_random_uuid(),
    created_at  timestamptz not null default now(),
    employee_id uuid        not null references employees(id) on delete cascade,
    type        text        not null,
    name        text,
    issued_on   date,
    expires_on  date
);

-- ============================================================
-- 2) COLUMN BACKFILLS for older databases
-- ============================================================
alter table leads  add column if not exists status         text    not null default 'new';
alter table leads  add column if not exists notified_email boolean not null default false;
alter table leads  add column if not exists notified_sms   boolean not null default false;
alter table shifts add column if not exists employee_response text  not null default 'pending'
    check (employee_response in ('pending', 'accepted', 'declined'));

-- ============================================================
-- 3) MIGRATE shifts.employee_id  (auth.users -> employees), if needed
-- ============================================================
do $$
declare
    fk_auth text;
    fk_emp  text;
begin
    -- Drop an old FK that still points at auth.users.
    select conname into fk_auth from pg_constraint
     where conrelid = 'public.shifts'::regclass and contype = 'f'
       and confrelid = 'auth.users'::regclass;
    if fk_auth is not null then
        execute format('alter table shifts drop constraint %I', fk_auth);
    end if;

    -- Remap any existing rows from the auth.users id to the matching employees.id.
    update shifts s set employee_id = e.id
      from employees e
     where s.employee_id = e.auth_user_id;

    -- Ensure the FK to employees exists.
    select conname into fk_emp from pg_constraint
     where conrelid = 'public.shifts'::regclass and contype = 'f'
       and confrelid = 'public.employees'::regclass;
    if fk_emp is null then
        alter table shifts add constraint shifts_employee_id_fkey
            foreign key (employee_id) references employees(id) on delete cascade;
    end if;
end $$;

-- ============================================================
-- 4) RLS + indexes
-- ============================================================
alter table leads          enable row level security;
alter table profiles       enable row level security;
alter table accounts       enable row level security;
alter table employees      enable row level security;
alter table shifts         enable row level security;
alter table availability   enable row level security;
alter table certifications enable row level security;

create index if not exists leads_created_at_idx      on leads (created_at desc);
create index if not exists leads_status_idx          on leads (status);
create index if not exists accounts_status_idx       on accounts (status);
create index if not exists employees_auth_user_idx   on employees (auth_user_id);
create index if not exists shifts_employee_id_idx    on shifts (employee_id);
create index if not exists shifts_start_at_idx       on shifts (start_at);
create index if not exists certifications_employee_idx on certifications (employee_id);
create index if not exists certifications_expires_idx  on certifications (expires_on);

-- ============================================================
-- 5) FUNCTIONS
-- ============================================================
create or replace function is_admin()
returns boolean language sql security definer stable as $$
    select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

-- Lets an employee accept/decline their own shift without a broad UPDATE policy:
-- updates ONLY the response column, ONLY on shifts assigned to them.
create or replace function respond_to_shift(p_shift_id uuid, p_response text)
returns void language plpgsql security definer as $$
begin
    if p_response not in ('accepted', 'declined') then
        raise exception 'invalid response: %', p_response;
    end if;
    update shifts s
       set employee_response = p_response
     where s.id = p_shift_id
       and s.employee_id in (select id from employees where auth_user_id = auth.uid());
    if not found then
        raise exception 'shift not found or not assigned to you';
    end if;
end;
$$;
grant execute on function respond_to_shift(uuid, text) to authenticated;

-- ============================================================
-- 6) POLICIES (drop then recreate so re-runs are clean)
-- ============================================================
drop policy if exists "profiles_select_own"        on profiles;
drop policy if exists "leads_admin_all"            on leads;
drop policy if exists "accounts_admin_all"         on accounts;
drop policy if exists "employees_admin_all"        on employees;
drop policy if exists "employees_select_own"       on employees;
drop policy if exists "employees_insert_own"       on employees;
drop policy if exists "employees_update_own"       on employees;
drop policy if exists "shifts_admin_all"           on shifts;
drop policy if exists "shifts_employee_own"        on shifts;
drop policy if exists "availability_admin_all"     on availability;
drop policy if exists "availability_employee_own"  on availability;
drop policy if exists "certifications_admin_all"   on certifications;
drop policy if exists "certifications_employee_own" on certifications;

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
    for select using (
        employee_id in (select id from employees where auth_user_id = auth.uid())
    );

create policy "availability_admin_all" on availability
    for all using (is_admin()) with check (is_admin());
create policy "availability_employee_own" on availability
    for all using (auth.uid() = employee_id) with check (auth.uid() = employee_id);

create policy "certifications_admin_all" on certifications
    for all using (is_admin()) with check (is_admin());
create policy "certifications_employee_own" on certifications
    for all using (
        employee_id in (select id from employees where auth_user_id = auth.uid())
    ) with check (
        employee_id in (select id from employees where auth_user_id = auth.uid())
    );

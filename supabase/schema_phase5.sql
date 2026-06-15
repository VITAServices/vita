-- VITA Services -- Phase 5 migration
-- Certification tracker: store structured certifications with expiry dates so the
-- admin can flag anything expiring within 30 days, and employees can manage their own.
--
-- Run this ONCE in the Supabase SQL Editor AFTER schema_phase4.sql.
-- It is safe to re-run.

create table if not exists certifications (
    id          uuid        primary key default gen_random_uuid(),
    created_at  timestamptz not null default now(),
    employee_id uuid        not null references employees(id) on delete cascade,
    type        text        not null,   -- 'CPR', 'First Aid', 'Nursing License', 'Other', ...
    name        text,                    -- issuing body / license number / notes
    issued_on   date,
    expires_on  date
);
alter table certifications enable row level security;
create index if not exists certifications_employee_idx on certifications (employee_id);
create index if not exists certifications_expires_idx  on certifications (expires_on);

-- RLS: admin manages everyone; an employee manages only their own rows.
drop policy if exists "certifications_admin_all"    on certifications;
drop policy if exists "certifications_employee_own" on certifications;

create policy "certifications_admin_all" on certifications
    for all using (is_admin()) with check (is_admin());

create policy "certifications_employee_own" on certifications
    for all using (
        employee_id in (select id from employees where auth_user_id = auth.uid())
    ) with check (
        employee_id in (select id from employees where auth_user_id = auth.uid())
    );

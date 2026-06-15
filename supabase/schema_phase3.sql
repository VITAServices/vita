-- VITA Services -- Phase 3 migration
-- Admin portal: shift assignment, dashboard KPIs, lead Kanban, payroll export.
--
-- The only schema change is re-pointing shifts.employee_id from auth.users(id)
-- to employees(id) so the admin can assign shifts to ANY roster employee,
-- not just those who have already activated their portal login.
--
-- Run this ONCE in the Supabase SQL Editor AFTER schema_all.sql:
-- https://supabase.com/dashboard/project/jeubjslsrnccdqjmlmsf/sql/new
-- It is safe to re-run.

-- Step 1: drop the policies that depend on shifts.employee_id so we can alter it.
drop policy if exists "shifts_admin_all"    on shifts;
drop policy if exists "shifts_employee_own" on shifts;

-- Step 2: drop the old foreign key to auth.users (name may vary across projects).
do $$
declare
    fk_name text;
begin
    select conname into fk_name
    from pg_constraint
    where conrelid = 'shifts'::regclass
      and contype = 'f'
      and confrelid = 'auth.users'::regclass;
    if fk_name is not null then
        execute format('alter table shifts drop constraint %I', fk_name);
    end if;
end $$;

-- Step 3: remap any existing shift rows from the auth.users id to the
-- matching employees.id (rows with no matching employee are left as-is and
-- will be rejected by the new FK -- delete them manually if that happens).
update shifts s
set employee_id = e.id
from employees e
where s.employee_id = e.auth_user_id;

-- Step 4: add the new foreign key to employees(id).
alter table shifts
    add constraint shifts_employee_id_fkey
    foreign key (employee_id) references employees(id) on delete cascade;

-- Step 5: recreate the policies.
-- Admin keeps full access.
create policy "shifts_admin_all" on shifts
    for all using (is_admin()) with check (is_admin());

-- An employee can read the shifts assigned to their own roster row.
create policy "shifts_employee_own" on shifts
    for select using (
        employee_id in (select id from employees where auth_user_id = auth.uid())
    );

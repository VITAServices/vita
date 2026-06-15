-- VITA Services -- verification of phase 3 + phase 4 migrations.
-- Read-only. Paste into the Supabase SQL Editor and check each result.
-- https://supabase.com/dashboard/project/jeubjslsrnccdqjmlmsf/sql/new

-- 1) shifts.employee_id must reference EMPLOYEES (not auth.users). Expect: employees
select c.conname as constraint_name,
       (select relname from pg_class where oid = c.confrelid) as references_table
from pg_constraint c
where c.conrelid = 'public.shifts'::regclass and c.contype = 'f';

-- 2) shifts.employee_response column must exist. Expect: one row, default 'pending'
select column_name, data_type, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'shifts' and column_name = 'employee_response';

-- 3) respond_to_shift() must exist and be SECURITY DEFINER. Expect: security_definer = true
select proname, prosecdef as security_definer
from pg_proc
where proname = 'respond_to_shift';

-- 4) RLS policies on shifts. Expect: shifts_admin_all (ALL) + shifts_employee_own (SELECT)
select policyname, cmd
from pg_policies
where schemaname = 'public' and tablename = 'shifts';

-- 5) Sanity: list shifts with their employee names through the new FK.
--    Should run without error and show employee names if any shifts exist.
select s.id, e.first_name || ' ' || e.last_name as employee, s.client_name,
       s.status, s.employee_response, s.start_at
from shifts s
join employees e on e.id = s.employee_id
order by s.start_at desc
limit 10;

-- 6) Phase 5: certifications table must exist with expected columns.
select column_name, data_type
from information_schema.columns
where table_schema = 'public' and table_name = 'certifications'
order by ordinal_position;

-- 7) certifications RLS policies. Expect: certifications_admin_all + certifications_employee_own
select policyname, cmd
from pg_policies
where schemaname = 'public' and tablename = 'certifications';

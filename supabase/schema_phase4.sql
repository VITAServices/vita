-- VITA Services -- Phase 4 migration
-- Employee portal: shift accept / decline.
--
-- Employees only have SELECT on their own shifts (shifts_employee_own). Rather
-- than open up a broad UPDATE policy (which can't restrict WHICH columns change),
-- we add a single response column and a SECURITY DEFINER function that updates
-- ONLY that column, ONLY on shifts that belong to the calling user.
--
-- Run this ONCE in the Supabase SQL Editor AFTER schema_phase3.sql.
-- It is safe to re-run.

-- Step 1: track the employee's response to an assigned shift.
alter table shifts add column if not exists employee_response text not null default 'pending'
    check (employee_response in ('pending', 'accepted', 'declined'));

-- Step 2: the only way an employee can change a shift -- and only the response.
create or replace function respond_to_shift(p_shift_id uuid, p_response text)
returns void
language plpgsql
security definer
as $$
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

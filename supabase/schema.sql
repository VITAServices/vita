-- Phase 1: lead capture
-- Run this once in the Supabase SQL Editor (Project > SQL Editor > New query)

create table if not exists leads (
    id uuid primary key default gen_random_uuid(),
    created_at timestamptz not null default now(),
    source text not null check (source in ('care_request', 'job_application')),
    first_name text not null,
    last_name text not null,
    email text not null,
    phone text not null,
    details jsonb not null default '{}'::jsonb,
    status text not null default 'new' check (status in ('new', 'contacted', 'converted', 'lost')),
    notified_email boolean not null default false,
    notified_sms boolean not null default false
);

create index if not exists leads_created_at_idx on leads (created_at desc);
create index if not exists leads_status_idx on leads (status);

-- Row Level Security: locked down by default. The website talks to this table
-- only through the serverless function, which uses the service_role key and
-- bypasses RLS — so no public policies are needed for Phase 1.
alter table leads enable row level security;

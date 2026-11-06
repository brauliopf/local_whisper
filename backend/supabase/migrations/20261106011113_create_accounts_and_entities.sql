create extension if not exists vector with schema extensions;

create table if not exists public.accounts (
  id uuid primary key,
  created_at timestamptz not null default now()
);

insert into public.accounts (id)
values ('00000000-0000-4000-8000-000000000001')
on conflict (id) do nothing;

create table if not exists public.entities (
  id bigint generated always as identity primary key,
  account_id uuid not null references public.accounts(id) on delete cascade,
  name text not null,
  type text not null check (type in ('PERSON', 'ORGANIZATION', 'PLACE', 'SYSTEM')),
  description text not null,
  embedding extensions.vector(1536) not null,
  created_at timestamptz not null default now()
);

create index if not exists entities_account_id_idx
  on public.entities (account_id);

alter table public.accounts enable row level security;
alter table public.entities enable row level security;

-- The backend uses the Supabase secret key; no client-facing policies are granted.

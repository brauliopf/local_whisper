create table if not exists public.conversations (
  id text primary key,
  created_at timestamptz not null default now()
);

create table if not exists public.messages (
  id bigint generated always as identity primary key,
  conversation_id text not null references public.conversations(id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  content text not null,
  created_at timestamptz not null default now()
);

create index if not exists messages_conversation_order_idx
  on public.messages (conversation_id, id);

alter table public.conversations enable row level security;
alter table public.messages enable row level security;

-- The backend uses the Supabase secret key; no client-facing policies are granted.

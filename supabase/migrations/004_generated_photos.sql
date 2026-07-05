-- supabase/migrations/004_generated_photos.sql
create table generated_photos (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  character_id uuid not null references characters(id) on delete cascade,
  user_id uuid not null,
  url text not null,
  created_at timestamptz not null default now()
);

alter table generated_photos enable row level security;

create policy "select own generated photos" on generated_photos
  for select using (user_id = auth.uid());

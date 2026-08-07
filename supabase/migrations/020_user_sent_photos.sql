-- User-sent photos used to live ONLY on-device (Message.localImagePath, never
-- uploaded), so they vanished the moment the local cache missed and history
-- had to reload from the server (server never knew they existed). This gives
-- them a real, persisted home: a private Storage bucket + a tracking table,
-- kept for 7 days, then swept to a placeholder (see chat/index.ts sweep on
-- history read — no pg_cron needed, checked lazily whenever history loads).

insert into storage.buckets (id, name, public)
values ('user-photos', 'user-photos', false)
on conflict (id) do nothing;

create table user_sent_photos (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null references messages(id) on delete cascade,
  conversation_id uuid not null references conversations(id) on delete cascade,
  storage_path text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  expired boolean not null default false
);

create index user_sent_photos_conversation_id_idx on user_sent_photos (conversation_id);
create index user_sent_photos_expiry_sweep_idx on user_sent_photos (expires_at) where not expired;

alter table user_sent_photos enable row level security;

create policy user_sent_photos_own_read on user_sent_photos for select
  using (exists (
    select 1 from conversations c
    where c.id = user_sent_photos.conversation_id and c.user_id = auth.uid()
  ));

-- Storage RLS: owner-scoped by path prefix (`{conversationId}/...`) — the
-- client uploads directly to Storage with the user's own JWT (not through an
-- edge function), so this is the only gate. Path prefix is trusted here
-- because the client controls it, mirroring how the "characters" bucket's
-- public-read policy already trusts caller-supplied paths for this project.
create policy user_photos_owner_insert on storage.objects for insert
  with check (
    bucket_id = 'user-photos'
    and exists (
      select 1 from conversations c
      where c.user_id = auth.uid()
        and (storage.foldername(name))[1] = c.id::text
    )
  );

create policy user_photos_owner_read on storage.objects for select
  using (
    bucket_id = 'user-photos'
    and exists (
      select 1 from conversations c
      where c.user_id = auth.uid()
        and (storage.foldername(name))[1] = c.id::text
    )
  );

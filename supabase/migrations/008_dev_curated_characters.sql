-- 007_dev_curated_characters.sql
--
-- DEV-only curated character creator: adds the in-chat curated photo pool
-- (character_photos existed only in schema.sql on paper, never actually
-- created on the live DB — created here for real) plus a per-character
-- voice_id override for ElevenLabs TTS (see supabase/functions/dev-create-character,
-- dev-upload-image, dev-list-voices, and chat-image/voice-message-tts changes).

create table if not exists character_photos (
  id           uuid primary key default gen_random_uuid(),
  character_id uuid references characters(id) on delete cascade,
  url          text not null,                       -- Storage public URL
  tags         text[] not null default '{}',        -- ör. {selfie, beach, outfit}
  mood         text,
  min_relationship_level int not null default 1,     -- bu seviyeden önce açılmaz
  is_pro       boolean not null default false,       -- yalnız PRO'ya açık mı
  sort         int not null default 0,
  -- Dev-written freeform description used by chat-image's Grok semantic
  -- match to decide whether an uploaded photo already satisfies a chat photo
  -- request, instead of generating a brand-new image.
  description  text,
  created_at   timestamptz not null default now()
);
create index if not exists character_photos_char_idx
  on character_photos(character_id, min_relationship_level);

alter table character_photos enable row level security;
drop policy if exists "character_photos_public_read" on character_photos;
create policy "character_photos_public_read" on character_photos
  for select to anon, authenticated using (true);
-- No insert/update/delete policy — writes only via service_role edge functions
-- (dev-create-character), same pattern as `characters` itself.

-- Per-character ElevenLabs voice override. NULL keeps today's behavior:
-- voice-message-tts derives the voice from personality_role + vibe via
-- elevenVoiceMap.ts. Curated characters can pin an exact voice instead.
alter table characters add column if not exists voice_id text;

-- aiGirlfriend — Supabase şeması
-- Çalıştır: Supabase Dashboard > SQL Editor > yapıştır > Run
-- (Free tier ile başlanır; +18 hacmi büyüyünce self-hosted Supabase'e geçilir.)

-- Vektör/uzun bellek için pgvector
create extension if not exists vector;

-- Karakterler (persona). Uygulama açılışta (splash) buradan çeker.
create table if not exists characters (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  tagline     text,
  system_prompt text not null,
  avatar_symbol text default 'person.crop.circle.fill',
  -- Feed/profil bilgileri
  age         int,
  city        text,
  country     text,
  profession  text,
  category    text,                       -- 'Realistic' | 'Fantasy' | 'Anime' (Tümünü Gör filtresi)
  photo_url   text,                       -- tam ekran büyük foto (Storage public URL)
  avatar_url  text,                       -- küçük daire avatar (Storage public URL)
  -- Profil sayfası: her karaktere özel, splash'te çekilir
  interests        jsonb not null default '[]'::jsonb,  -- ilgi alanları (emoji+metin)
  relationship_level int not null default 0,            -- ilişki seviyesi (0 başlar, artar)
  gallery_urls     jsonb not null default '[]'::jsonb,  -- profildeki kaydırılabilir resimler
  chat_photos      jsonb not null default '[]'::jsonb,  -- kızın sohbette gönderebileceği hazır fotolar
  created_at  timestamptz not null default now()
);

-- Mevcut kurulumlar için eksik kolonları garantiye al
alter table characters
  add column if not exists age int,
  add column if not exists city text,
  add column if not exists country text,
  add column if not exists profession text,
  add column if not exists category text,
  add column if not exists photo_url text,
  add column if not exists avatar_url text,
  add column if not exists interests jsonb not null default '[]'::jsonb,
  add column if not exists relationship_level int not null default 0,
  add column if not exists gallery_urls jsonb not null default '[]'::jsonb,
  add column if not exists chat_photos jsonb not null default '[]'::jsonb,
  -- DEV-curated characters only (bkz. dev-create-character) — per-character
  -- ElevenLabs override; null keeps the default role+vibe map.
  add column if not exists voice_id text;

-- Karakter görselleri için public storage bucket'ı
insert into storage.buckets (id, name, public)
values ('characters', 'characters', true)
on conflict (id) do update set public = true;

-- RLS: characters herkese açık katalog verisidir; anon okuyabilir.
-- (Diğer tablolar RLS açık + politika yok = kapalı; sadece bu okunabilir.)
alter table characters enable row level security;
drop policy if exists "characters_public_read" on characters;
create policy "characters_public_read" on characters
  for select to anon, authenticated using (true);

-- Karaktere ait sohbette gönderilebilecek fotoğraflar (galeri = Storage'daki dosyalar).
-- "Kız foto gönderir" = buradan seviyeye/PRO'ya uygun bir kayıt seçilir.
create table if not exists character_photos (
  id           uuid primary key default gen_random_uuid(),
  character_id uuid references characters(id) on delete cascade,
  url          text not null,                       -- Storage public URL
  tags         text[] not null default '{}',        -- ör. {selfie, beach, outfit}
  mood         text,
  min_relationship_level int not null default 1,     -- bu seviyeden önce açılmaz
  is_pro       boolean not null default false,       -- yalnız PRO'ya açık mı
  sort         int not null default 0,
  -- DEV-yazılan serbest metin açıklama — chat-image'ın Grok eşleşmesi bunu
  -- kullanıcının fotoğraf isteğiyle karşılaştırır (bkz. dev-create-character,
  -- chat-image/index.ts pickCuratedPhoto).
  description  text,
  created_at   timestamptz not null default now()
);
create index if not exists character_photos_char_idx
  on character_photos(character_id, min_relationship_level);

alter table character_photos enable row level security;
drop policy if exists "character_photos_public_read" on character_photos;
create policy "character_photos_public_read" on character_photos
  for select to anon, authenticated using (true);

-- conversations: kullanıcı yalnızca kendi sohbetlerini okuyabilir (chat listesi).
drop policy if exists "conversations_own_read" on conversations;
create policy "conversations_own_read" on conversations
  for select to authenticated using (auth.uid() = user_id);

-- Kullanıcı-karakter konuşmaları
create table if not exists conversations (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid,                       -- Supabase Auth user id
  character_id uuid references characters(id),
  title       text,
  -- eski turların özetlenmiş hali (katmanlı bellek: "özet bellek")
  summary     text default '',
  -- şimdiye kadar kaç eski mesajın özete sıkıştırıldığı (Edge Function takip eder)
  summarized_count int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Mevcut kurulumlar için: tablo zaten varsa "create table if not exists" kolonu
-- eklemez; bu yüzden eksik kolonu ayrıca garantiye alıyoruz.
-- xp/relationship_level/msg_counter: ilişki seviyesi sistemi (kullanıcı+karaktere özel).
alter table conversations
  add column if not exists summarized_count int not null default 0,
  add column if not exists xp int not null default 0,
  add column if not exists relationship_level int not null default 1,
  add column if not exists msg_counter int not null default 0;

-- Tüm mesajlar (kalıcı sohbet geçmişi)
create table if not exists messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid references conversations(id) on delete cascade,
  role            text not null check (role in ('user','assistant','system')),
  content         text not null,
  created_at      timestamptz not null default now()
);
create index if not exists messages_conv_idx on messages(conversation_id, created_at);

-- Mesaj tipi: 'text' | 'image' | 'voice'. image/voice'ta content = Storage URL.
alter table messages
  add column if not exists kind text not null default 'text';

-- Kalıcı gerçekler / anılar (RAG için embedding'li).
-- 500. turda "ilk buluşmamızı hatırlıyor musun" -> buradan benzerlik aramasıyla çekilir.
-- 1536 boyut: birçok embedding modeline uyar; kullandığın modele göre ayarla.
create table if not exists memories (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid references conversations(id) on delete cascade,
  content         text not null,           -- "kullanıcı kedisini sever", "X'e aşık" vb.
  embedding       vector(1536),
  created_at      timestamptz not null default now()
);

-- Benzerlik araması için yaklaşık indeks (cosine)
create index if not exists memories_embedding_idx
  on memories using hnsw (embedding vector_cosine_ops);

-- Bir konuşma için en alakalı anıları getiren yardımcı fonksiyon (RAG)
create or replace function match_memories(
  p_conversation_id uuid,
  p_query_embedding vector(1536),
  p_match_count int default 5
)
returns table (id uuid, content text, similarity float)
language sql stable as $$
  select m.id, m.content,
         1 - (m.embedding <=> p_query_embedding) as similarity
  from memories m
  where m.conversation_id = p_conversation_id
  order by m.embedding <=> p_query_embedding
  limit p_match_count;
$$;

-- ── Personality role system (migration 001) ──────────────────────────────────

-- New columns on characters
alter table characters
  add column if not exists personality_role text not null default 'flirty',
  add column if not exists created_by uuid references auth.users(id),
  add column if not exists builder_selections jsonb,
  add column if not exists ex_history text;

-- Role-level directives: 7 roles x 10 levels = 70 rows (seeded via seed_role_level_scripts.sql)
create table if not exists role_level_scripts (
  role      text not null,
  level     int  not null,
  directive text not null,
  primary key (role, level)
);

alter table role_level_scripts enable row level security;
drop policy if exists "role_level_scripts_read" on role_level_scripts;
create policy "role_level_scripts_read" on role_level_scripts
  for select to authenticated using (true);

-- Optional per-character directive overrides (takes priority over role template)
create table if not exists character_level_overrides (
  character_id uuid references characters(id) on delete cascade,
  level        int  not null,
  directive    text not null,
  primary key (character_id, level)
);

alter table character_level_overrides enable row level security;
drop policy if exists "character_level_overrides_read" on character_level_overrides;
create policy "character_level_overrides_read" on character_level_overrides
  for select to authenticated using (true);


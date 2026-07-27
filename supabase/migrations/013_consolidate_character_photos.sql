-- Migration 013: consolidate all character photos into character_photos
--
-- Before this, character photos lived in five different places:
--   characters.photo_url / avatar_url  (scalar profile pics)
--   characters.gallery_urls            (jsonb array, profile carousel)
--   character_photos                   (shared in-chat pool, public RLS)
--   generated_photos                   (private per-user AI photos, own RLS)
--
-- character_photos becomes the single catalog: is_generated/is_uploaded track
-- origin, show_in_gallery/show_in_chat/show_as_profile_picture track where it's
-- used, and (nullable) user_id/conversation_id + is_private/reacted carry over
-- the private per-user generated-photo model behind split RLS.
--
-- characters.photo_url/avatar_url/gallery_urls are NOT dropped here — they
-- stay as the fast scalar source the feed/profile views read; this backfill
-- just mirrors them into the catalog. generated_photos is NOT dropped here
-- either (see migration 014, pushed only after edge functions/client are
-- verified against the new columns).

alter table character_photos
  add column if not exists is_generated boolean not null default false,
  add column if not exists is_uploaded  boolean not null default false,
  add column if not exists show_in_gallery         boolean not null default false,
  add column if not exists show_in_chat            boolean not null default false,
  add column if not exists show_as_profile_picture boolean not null default false,
  add column if not exists user_id         uuid references auth.users(id) on delete cascade,
  add column if not exists conversation_id uuid references conversations(id) on delete cascade,
  add column if not exists is_private boolean not null default false,
  add column if not exists reacted    boolean not null default false;

create index if not exists character_photos_user_idx
  on character_photos(user_id, character_id);

-- RLS: split public catalog rows (user_id null) from private per-user rows,
-- replacing the old unconditional public-read policy.
drop policy if exists "character_photos_public_read" on character_photos;

create policy "character_photos_catalog_read" on character_photos
  for select to anon, authenticated using (user_id is null);

create policy "character_photos_owner_read" on character_photos
  for select to authenticated using (user_id = auth.uid());

-- === Backfill ===

-- Existing character_photos rows are the shared in-chat pool.
update character_photos set show_in_chat = true where show_in_chat = false;

-- gallery_urls jsonb array -> one row per url, preserving order via `sort`.
insert into character_photos (character_id, url, show_in_gallery, sort, is_uploaded)
select c.id, url_elem, true, ord - 1, true
from characters c,
     lateral jsonb_array_elements_text(coalesce(c.gallery_urls, '[]'::jsonb)) with ordinality as t(url_elem, ord)
where url_elem is not null and url_elem <> '';

-- photo_url / avatar_url -> profile-picture mirror rows (dedupe when equal).
insert into character_photos (character_id, url, show_as_profile_picture, is_uploaded)
select id, photo_url, true, true from characters where photo_url is not null and photo_url <> '';

insert into character_photos (character_id, url, show_as_profile_picture, is_uploaded)
select id, avatar_url, true, true
from characters
where avatar_url is not null and avatar_url <> '' and avatar_url is distinct from photo_url;

-- generated_photos -> private per-user rows.
insert into character_photos (
  character_id, url, user_id, conversation_id, is_private, reacted,
  is_generated, show_in_gallery, created_at
)
select character_id, url, user_id, conversation_id, is_private, reacted,
       true, true, created_at
from generated_photos;

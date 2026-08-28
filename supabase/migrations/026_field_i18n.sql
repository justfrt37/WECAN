-- Migration 026: per-locale profession + interests
--
-- Same pattern as tagline_i18n (011_tagline_i18n.sql): `profession` and
-- `interests` are plain canonical columns (now English, see the
-- character-language cleanup that goes with this migration), and these two
-- new jsonb columns hold locale -> translation maps. Client falls back to
-- the canonical column whenever a locale is missing (see
-- Character.localizedProfession / localizedInterests).
--
-- profession_i18n shape:  {"en": "Nurse", "tr": "Hemşire", ...}
-- interests_i18n shape:   {"en": ["🎨 Painting", ...], "tr": ["🎨 Resim", ...]}
--   (array is positionally aligned with the canonical `interests` array —
--   client only trusts a translation whose length matches).
--
-- characters_review was created with `like characters including all`
-- (019_review_mode.sql) and does NOT auto-inherit later ALTERs, so it needs
-- the same two columns explicitly.

alter table characters
  add column if not exists profession_i18n jsonb not null default '{}'::jsonb,
  add column if not exists interests_i18n  jsonb not null default '{}'::jsonb;

alter table characters_review
  add column if not exists profession_i18n jsonb not null default '{}'::jsonb,
  add column if not exists interests_i18n  jsonb not null default '{}'::jsonb;

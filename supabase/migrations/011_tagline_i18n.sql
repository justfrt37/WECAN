-- Migration 010: per-locale character taglines
--
-- characters.tagline has always been a single plain-text column, authored
-- in Turkish by the bio-generation prompts in create-character/
-- dev-create-character. Every user saw the same Turkish tagline regardless
-- of the app's UI language (7 locales, see Localizable.xcstrings /
-- ConversationLanguage.swift). tagline_i18n holds a locale -> text map
-- ({"tr": "...", "en": "...", ...}); `tagline` stays as-is (Turkish
-- canonical text) and is now also the fallback when a locale is missing
-- from tagline_i18n (old rows, or a language the translation call failed
-- for).

alter table characters
  add column if not exists tagline_i18n jsonb not null default '{}'::jsonb;

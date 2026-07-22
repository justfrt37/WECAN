-- Migration 009: drop dead characters.chat_photos column
--
-- Legacy jsonb column from the original schema, superseded by the
-- normalized character_photos table (migration 007). Nothing has written
-- to characters.chat_photos since 007 landed — dev-create-character/
-- dev-update-character write chatPhotos into character_photos, and
-- chat-image reads the in-chat photo pool from character_photos too.
-- Character.swift's corresponding `chatPhotos` property was unused
-- everywhere else in the app and has been removed alongside this column.

alter table characters drop column if exists chat_photos;

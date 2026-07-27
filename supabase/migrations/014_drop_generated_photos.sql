-- Migration 014: drop generated_photos
--
-- Superseded by character_photos (migration 013) — private per-user AI
-- photos now live there with user_id/conversation_id/is_private/reacted.
-- DO NOT push this until chat-image/chat edge functions are deployed and
-- verified against character_photos (see migration 013's header comment).

drop table if exists generated_photos;

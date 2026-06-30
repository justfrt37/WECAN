-- Migration 002: Per-conversation behavior notes ("Davranış Ekle").
-- Mirrors the existing `memories` table shape (minus embedding) — behavior
-- preferences the user has asked their character to follow, scoped to
-- their own (user, character) conversation so it never leaks to other
-- users chatting with the same catalog character.

CREATE TABLE IF NOT EXISTS conversation_behaviors (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid REFERENCES conversations(id) ON DELETE CASCADE,
  content         text NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS conversation_behaviors_conv_idx
  ON conversation_behaviors(conversation_id, created_at);

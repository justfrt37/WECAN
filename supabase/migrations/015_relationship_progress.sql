-- 008_relationship_progress.sql
-- İlişki seviyesi ilerlemesi artık SUNUCUDA hesaplanır (istemci sadece gösterir).
-- `relationship_level` zaten vardı; güncel seviyenin ilerleme oranını (0..1)
-- tutmak için `level_progress` eklenir. Her mesajda sunucu bu oranı artırır,
-- dolunca seviye atlar (bkz. chat/index.ts applyGain).

ALTER TABLE conversations
  ADD COLUMN IF NOT EXISTS level_progress double precision NOT NULL DEFAULT 0;

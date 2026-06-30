-- Migration 001: Character personality roles + level script tables

-- 1. Add new columns to characters
ALTER TABLE characters
  ADD COLUMN IF NOT EXISTS personality_role text NOT NULL DEFAULT 'flirty',
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS builder_selections jsonb,
  ADD COLUMN IF NOT EXISTS ex_history text;

-- 2. Assign roles to existing 5 system characters
UPDATE characters SET personality_role = 'devoted' WHERE id = '00000000-0000-0000-0000-000000000001'; -- Elif
UPDATE characters SET personality_role = 'flirty'  WHERE id = '00000000-0000-0000-0000-000000000002'; -- Aria
UPDATE characters SET personality_role = 'playful' WHERE id = '00000000-0000-0000-0000-000000000003'; -- Alicia
UPDATE characters SET personality_role = 'shy'     WHERE id = '00000000-0000-0000-0000-000000000004'; -- Mia
UPDATE characters SET personality_role = 'distant' WHERE id = '00000000-0000-0000-0000-000000000005'; -- Sophia

-- 3. role_level_scripts: 7 roles x 10 levels = 70 rows (seeded separately)
CREATE TABLE IF NOT EXISTS role_level_scripts (
  role      text NOT NULL,
  level     int  NOT NULL,
  directive text NOT NULL,
  PRIMARY KEY (role, level)
);

-- 4. character_level_overrides: optional per-character per-level overrides
CREATE TABLE IF NOT EXISTS character_level_overrides (
  character_id uuid REFERENCES characters(id) ON DELETE CASCADE,
  level        int  NOT NULL,
  directive    text NOT NULL,
  PRIMARY KEY (character_id, level)
);

-- 5. RLS: both tables readable by authenticated users; only service_role writes
ALTER TABLE role_level_scripts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "role_level_scripts_read" ON role_level_scripts;
CREATE POLICY "role_level_scripts_read" ON role_level_scripts
  FOR SELECT TO authenticated USING (true);

ALTER TABLE character_level_overrides ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "character_level_overrides_read" ON character_level_overrides;
CREATE POLICY "character_level_overrides_read" ON character_level_overrides
  FOR SELECT TO authenticated USING (true);

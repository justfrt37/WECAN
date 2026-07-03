-- Backfills builder_selections->>'vibe' for the real live catalog characters.
-- NOTE: supabase/seed_characters.sql describes a 15-character catalog that was
-- never actually run against this database — the live catalog is just the 6
-- characters below (5 from migration 001_character_roles.sql + Sofia, added
-- separately). Do not confuse the two.
--
-- Sofia (0cae386a-cb34-4652-a993-b2ae92e6b806) already has a vibe set
-- ("Mysterious") — left untouched here.

update characters set builder_selections = jsonb_build_object('vibe', 'Sweet')
  where id = '00000000-0000-0000-0000-000000000001'; -- Elif (devoted)
update characters set builder_selections = jsonb_build_object('vibe', 'Sweet')
  where id = '00000000-0000-0000-0000-000000000002'; -- Aria (flirty)
update characters set builder_selections = jsonb_build_object('vibe', 'Energetic')
  where id = '00000000-0000-0000-0000-000000000003'; -- Alicia (playful)
update characters set builder_selections = jsonb_build_object('vibe', 'Sweet')
  where id = '00000000-0000-0000-0000-000000000004'; -- Mia (shy)
update characters set builder_selections = jsonb_build_object('vibe', 'Mysterious')
  where id = '00000000-0000-0000-0000-000000000005'; -- Sophia (distant)

-- supabase/migrations/005_generated_photos_private_flag.sql
alter table generated_photos
  add column is_private boolean not null default false,
  add column reacted boolean not null default false;

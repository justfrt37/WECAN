-- 020's storage policies keyed the path prefix off conversation_id, but the
-- client doesn't reliably know conversationId before the FIRST message ever
-- creates the conversation row server-side — a real race for a brand new
-- chat. Re-key by uid instead (`{uid}/{filename}`), which the client always
-- has upfront.

drop policy if exists user_photos_owner_insert on storage.objects;
drop policy if exists user_photos_owner_read on storage.objects;

create policy user_photos_owner_insert on storage.objects for insert
  with check (
    bucket_id = 'user-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy user_photos_owner_read on storage.objects for select
  using (
    bucket_id = 'user-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- `messages.read_at timestamptz` → `messages.is_read boolean` (kullanıcı talebi).
--
-- Migration 030 okunma ANINI tutuyordu; istenen ise düz bir okundu/okunmadı
-- bayrağı. Kaybedilen tek şey "ne zaman okundu" bilgisi — hiçbir yerde
-- kullanılmıyordu (rozet yalnızca null/değil ayrımına bakıyordu), o yüzden
-- göç bilgi kaybı yaratmıyor.
--
-- SIRA ÖNEMLİ: kolon `default false` ile eklendiği için TÜM satırlar önce
-- false olur; okunmuş satırları geri kazanmanın tek yolu read_at hâlâ
-- ayaktayken backfill yapmak. Bu yüzden düşürme (drop) en sonda.

alter table public.messages
  add column if not exists is_read boolean not null default false;

-- read_at dolu olan satır = okunmuş. (030'un backfill'i geçmiş bot
-- mesajlarının hepsine read_at = created_at yazmıştı, yani o bilgi burada
-- korunuyor.)
update public.messages
   set is_read = true
 where read_at is not null
   and is_read = false;

-- Kısmi indeks yeni kolona taşınıyor. Eskisi read_at'e bağlı olduğu için
-- kolon düşerken zaten geçersizleşir; açıkça siliyoruz ki adı yeniden
-- kullanılabilir olsun.
drop index if exists public.messages_unread_idx;
create index if not exists messages_unread_idx
  on public.messages (conversation_id)
  where role = 'assistant' and is_read = false;

-- Fonksiyon yeni kolonu yazıyor. İmza (uuid → integer) ve sahiplik kontrolü
-- 030'daki gibi: `security definer` ama YALNIZCA çağıranın kendi konuşması
-- (conversations.user_id = auth.uid()); o kontrol olmadan definer yetkisi
-- başkasının konuşmasını okundu işaretlemeye izin verirdi.
create or replace function public.mark_conversation_read(p_character_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated integer;
begin
  if auth.uid() is null then
    raise exception 'unauthenticated';
  end if;

  update public.messages m
     set is_read = true
   where m.role = 'assistant'
     and m.is_read = false
     and m.conversation_id in (
       select c.id from public.conversations c
        where c.user_id = auth.uid()
          and c.character_id = p_character_id
     );

  get diagnostics v_updated = row_count;
  return v_updated;
end;
$$;

revoke all on function public.mark_conversation_read(uuid) from public;
grant execute on function public.mark_conversation_read(uuid) to authenticated;

alter table public.messages drop column if exists read_at;

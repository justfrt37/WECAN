-- Okundu bilgisi YALNIZCA bot mesajlarında olur (kullanıcı talebi).
--
-- 031 kolonu `not null default false` eklemişti; bu, kullanıcı mesajlarına da
-- `false` yazıyordu — yani "kullanıcının kendi mesajı okunmamış" gibi anlamsız
-- bir durum (canlı: 876 kullanıcı satırı, hepsi false). Okundu/okunmadı
-- kavramı sadece BOTUN gönderdiği mesaj için var.
--
-- Yeni kural: `is_read` bot mesajlarında true/false, kullanıcı mesajlarında
-- NULL. Kural bir CHECK ile ZORLANIYOR, sadece konvansiyon olarak
-- bırakılmıyor — aksi halde yeni bir insert yolu (ör. ileride başka bir edge
-- function) sessizce eski karışıklığı geri getirebilirdi.

alter table public.messages alter column is_read drop not null;
alter table public.messages alter column is_read drop default;

-- Kullanıcı satırlarındaki anlamsız false'ları temizle.
update public.messages set is_read = null where role <> 'assistant';

-- Varsayılanı TRIGGER veriyor, `default` DEĞİL: tek bir kolon varsayılanı
-- role'e bakamaz. chat/index.ts insert'leri bu kolonu hiç bilmiyor, o yüzden
-- doğru değeri veritabanının kendisi koymalı — böylece edge function'a
-- dokunmadan kural garanti altına alınıyor.
create or replace function public.messages_default_is_read()
returns trigger
language plpgsql
as $$
begin
  if new.role = 'assistant' then
    new.is_read := coalesce(new.is_read, false);   -- yeni bot mesajı = okunmamış
  else
    new.is_read := null;                            -- kullanıcı mesajında yok
  end if;
  return new;
end;
$$;

drop trigger if exists messages_default_is_read_trg on public.messages;
create trigger messages_default_is_read_trg
  before insert on public.messages
  for each row execute function public.messages_default_is_read();

alter table public.messages drop constraint if exists messages_is_read_role_chk;
alter table public.messages
  add constraint messages_is_read_role_chk
  check ((role = 'assistant') = (is_read is not null));

-- Kısmi indeks aynı kalıyor (`is_read = false` zaten yalnızca bot satırlarında
-- mümkün) ama NULL'ların indekse hiç girmediğini netleştirmek için yeniden
-- kuruluyor.
drop index if exists public.messages_unread_idx;
create index if not exists messages_unread_idx
  on public.messages (conversation_id)
  where role = 'assistant' and is_read = false;

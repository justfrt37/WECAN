-- Mesaj başına okundu bilgisi.
--
-- ÖNCESİ: okunmamış sayısı YALNIZCA cihazda tutuluyordu (ReadTracker,
-- UserDefaults'ta karakter başına "görülen bot mesajı SAYISI"). Üç sonucu vardı:
--   1. Uygulama silinip kurulunca ya da cihaz değişince sayaç sıfırlanıyor,
--      geçmişteki TÜM sohbetler yeniden okunmamış görünüyordu.
--   2. Sunucu kullanıcının bir mesajı okuyup okumadığını hiç bilmiyordu, yani
--      bildirim/proaktif mesaj kararları bu bilgiyi kullanamıyordu.
--   3. Sayaç ile gerçek liste uyuşmadığı anda rozet yanlış oluyordu (bkz.
--      "unread badge sticking on voice/photo messages" düzeltmeleri).
--
-- SONRASI: `messages.read_at` — okunma zamanı mesajın kendi satırında.
-- Okunmamış = `role = 'assistant' and read_at is null`.
--
-- GERİYE UYUMLU: kolon nullable ve varsayılanı yok. Bu kolonu bilmeyen eski
-- istemciler (ör. incelemede olan build) aynen çalışmaya devam eder; onlar
-- `read_at` seçmez ve mark_conversation_read'i çağırmaz.

alter table public.messages
  add column if not exists read_at timestamptz;

-- GEÇMİŞ VERİ: bu göç ANINDAN ÖNCEKİ bot mesajları okunmuş sayılıyor.
-- Alternatifi (hepsini okunmamış bırakmak) her kullanıcıya tek seferlik dev
-- bir okunmamış rozeti patlatırdı — cihazındaki yerel sayaca göre bunları
-- zaten okumuş olan kullanıcılar için tamamen yanlış bir sinyal.
update public.messages
   set read_at = created_at
 where role = 'assistant'
   and read_at is null;

-- Okunmamış sayımı için kısmi indeks: sorgu her zaman "assistant + read_at
-- null" filtresiyle geliyor, indeksin de yalnızca o satırları tutması yeterli
-- (okunmuş mesajlar zamanla çoğunluk olacak, onları indekslemek boşa yer).
create index if not exists messages_unread_idx
  on public.messages (conversation_id)
  where role = 'assistant' and read_at is null;

-- Bir karakterle olan konuşmanın okunmamış bot mesajlarını okundu işaretler.
--
-- ANAHTAR `character_id`, conversation_id DEĞİL: istemci bir conversationId'yi
-- HİÇ takip etmiyor — bu id her yerde sunucu tarafında (uid, characterId)'den
-- çözülüyor (bkz. chat/index.ts ve voice-call-start/index.ts'teki aynı desen;
-- orada client-supplied conversationId beklemek yapısal olarak hep undefined
-- geliyordu). Aynı hataya düşmemek için burada da çözüm sunucuda.
--
-- RPC olarak yazıldı, edge function olarak DEĞİL: iş tek bir UPDATE, araya
-- Deno çalışma zamanı sokmanın tek getirisi soğuk başlatma gecikmesi olurdu.
--
-- `security definer` ama SAHİPLİK KONTROLÜ ZORUNLU: yalnızca çağıranın KENDİ
-- konuşması işaretlenir (conversations.user_id = auth.uid()). Bu kontrol
-- olmadan definer yetkisi, herhangi bir kullanıcının başkasının konuşmasını
-- okundu işaretlemesine izin verirdi.
--
-- Aynı karaktere ait birden çok konuşma satırı olabiliyor (bkz. sohbet
-- listesinin "karakter başına tek satır" filtresi) — hepsi işaretlenir,
-- kullanıcı açısından o karakterle tek bir sohbet var.
--
-- Dönüş: gerçekten güncellenen satır sayısı. 0 dönmesi "işaretlenecek bir şey
-- yoktu" demek, hata değil.
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
     set read_at = now()
   where m.role = 'assistant'
     and m.read_at is null
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

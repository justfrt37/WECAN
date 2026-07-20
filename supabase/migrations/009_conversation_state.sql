-- 009_conversation_state.sql
-- "Sıfır yerel" geçişi: LocalConversationStore.Stored'da olup sunucuda karşılığı
-- olmayan durum alanlarını conversations tablosuna taşır. Böylece sohbet
-- durumunun TEK doğru kaynağı sunucu olur (bkz. docs/plan tender-cooking-bear).

alter table conversations add column if not exists schedule jsonb;
alter table conversations add column if not exists woken_up_at timestamptz;
alter table conversations add column if not exists manual_sleep_at timestamptz;
alter table conversations add column if not exists ghosted_at timestamptz;
alter table conversations add column if not exists detected_language text;

-- Şema kayması düzeltmesi: schema.sql `messages.kind`'i tanımlıyordu ama canlı
-- DB'ye hiç uygulanmamıştı (yerel-öncelikli mimaride sunucu mesaj-yazma yolu
-- atıl olduğu için fark edilmemişti). "Sıfır yerel"de sunucu artık HER mesajı
-- yazdığından bu sütun ŞART (yoksa insert patlar, fetchAllMessages 400 döner).
alter table messages add column if not exists kind text not null default 'text';

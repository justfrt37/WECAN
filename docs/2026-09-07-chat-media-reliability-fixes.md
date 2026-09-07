# Chat medya güvenilirliği — 2026-09-06/07 düzeltmeleri

Bu doc, tek bir oturumda (Claude Code) yapılan büyük bir düzeltme serisini
özetler — başka bir bilgisayardan devam edecek biri için. Kronolojik sırayla.

## 1. Bağlam — nereden başladı

Kullanıcı raporu: "Bota fotoğraf gönder butonuyla istek atıyoruz, bot generic
bir mesaj atıp fotoğrafı gönderiyor. Sonra uygulamayı kapatıp tekrar
açtığımda o fotoğraf VE mesaj kayboluyor."

Bu, üç ayrı denetim ajanının (general-purpose, paralel) çok detaylı taradığı
daha büyük bir "chat state senkronizasyonu" incelemesine çıktı. Ajanların
tam raporu bir Artifact olarak yayınlandı (bu konuşmada linki var, repo'da
değil — kaybolursa: aynı promptlarla tekrar üretilebilir, aşağıda özetli).

## 2. Kök neden zinciri

1. **`LocalConversationStore` artık tamamen bellek-içi** ("sıfır yerel"
   mimarisi, `f704755d` commit'i) — disk'e hiçbir şey yazmıyor. Bu BİLİNÇLİ
   bir karar (sunucu tek doğru kaynak).
2. Bu karardan SONRA yazılan iki fonksiyon (`appendBotLine`,
   `appendLocalMediaRequestLine`) "sunucuya gitmez, client-only" diye
   TASARLANMIŞTI — eski varsayımla çelişiyordu. Sonuç: bu iki mesaj türü
   HER ZAMAN kayboluyordu.
3. Ayrıca `photoDownloadReaction` cevabı da hiç `messages`'a yazılmıyordu.

## 3. İlk fix turu — persistence (commit `43c73bb9` civarı)

- `appendBotLine` / `appendLocalMediaRequestLine` → artık `injectProactive`
  (chat/index.ts) ile SUNUCUYA da yazıyor. `injectProactive`'e `role`
  (user/assistant) desteği eklendi (önceden hep assistant'tı).
- `photoDownloadReaction` → `messages` insert eklendi.
- Bu iş için `chat/index.ts` deploy edildi.

## 4. xAI foto oranı bozulması

Kullanıcı: "xAI generate ettiği fotolar chatte uzamış/incelmiş duruyor."
Gerçek dosya indirip piksel ölçüldü: `aspect_ratio: "9:16"` zorlanınca xAI
GERÇEKTEN 9:16 üretiyordu (1584×2816, sahte kırpma değil) ama İNSAN
VÜCUDUNU görünür şekilde bozarak. Karakter oluşturma (`create-character`)
aynı modeli oran vermeden çağırıyor, doğal varsayılan 3:4 (1776×2368),
bozulma YOK.

Fix: `chat-image/index.ts`'ten `aspect_ratio` parametresi TAMAMEN
kaldırıldı (hem edits hem generations çağrısı), prompt'taki "9:16 dikey
kanvas" talimatı 3:4'e çevrildi. `ChatView.swift`'teki foto balonu kutusu
220×390 → 220×293 (3:4).

Sonra: kullanıcı "bubble'ı sadece generated karakterler için mi
yapabilirdik" diye sordu — evet, URL path'inden ayırt edilebiliyordu
(`/generated/` = xAI taze üretim, `/curated/` = önceden çekilmiş gerçek
9:16 galeri fotoları). `ChatBubble.photoBubbleHeight(for:)` eklendi,
`/generated/` → 293 (3:4), `/curated/` → 390 (9:16).

## 5. Review mode'da karakterler kayboluyor

`CharacterStore.swift` `load()` — sunucu fetch 3 denemede de başarısız
olursa (bayat token, geçici ağ hatası) review modda `characters = []`
yazıyordu, adım 1'de disk cache'ten AZ ÖNCE yüklenen geçerli listenin
ÜZERİNE. Fix: sadece elimizde hiç cache yoksa boşalt, doluysa dokunma.
**Bu client-side Swift, yeni build gerektirir** — server'dan düzeltilemez.

## 6. Chat listesi cevap gelince yenilenmiyor

`applyPostReplyEffects` normal cevapta `store.conversationsVersion`'ı hiç
artırmıyordu (sadece proaktif/arka plan mesaj yolu artırıyordu).
`ChatListView` SADECE bu sayaç değişince yeniden yükleniyor — kullanıcı
mesaj atıp chatten çıkarsa (ya da listede kalırsa), cevap gelince
"yazıyor" göstergesi kapanıyordu ama önizleme/rozet donuk kalıyordu.
Fix: her cevapta koşulsuz artır.

## 7. Büyük denetim (3 paralel ajan) + fix turu

29 senaryo test edildi (kod okuma + gerçek Supabase DB sorgusu ile),
10 fail bulundu — 4'ü **gerçek para kaybı**. Tam liste yayınlanan
Artifact'te. Özet ve YAPILAN fix'ler:

### Para kaybı bug'ları (hepsi fix'lendi, commit `569bb18d`)

Kök neden: reveal (kilitli balon → gerçek içerik) eşleştirmesi
`content` + FIFO tahminine dayanıyordu, VE persist adımı ayrı bir
round-trip'te client'ın cevabı almasına bağlıydı.

**Fix — mimari değişiklik:** her pending balona kendi `client_request_id`'si
verildi (zaten var olan yerel mesaj UUID'si). `messages` tablosuna
`client_request_id uuid` kolonu eklendi (migration, doğrudan SQL ile).

- `chat-image/index.ts` ve `voice-message-tts/index.ts` artık:
  1. `client_request_id` ile pending satırı ATOMİK olarak claim ediyor
     (`kind` = `image_pending`/`voice_pending` → `image_claimed`/
     `voice_claimed`, `UPDATE ... WHERE kind=X RETURNING id`). İki
     eşzamanlı istek (iki cihaz, çift dokunuş) aynı satırı claim etmeye
     çalışırsa SADECE biri kazanır.
  2. Claim başarısızsa: satır zaten `image`/`voice` ise (tamamlanmış)
     AYNI sonucu tekrar ücretlendirmeden döner (idempotent retry);
     `image_claimed`/`voice_claimed` ise 409 `already_processing`;
     satır yoksa (eski client, clientRequestId göndermedi) ESKİ
     davranışa düşer.
  3. Üretim + charge (mevcut sıra/mantık AYNEN korundu).
  4. Herhangi bir hata adımında claim REVERT edilir (`revertClaim`) —
     satır tekrar `_pending`'e döner, kullanıcı tekrar deneyebilir.
  5. Başarıda satır DOĞRUDAN sunucuda finalize edilir (`kind`→`image`/
     `voice`, `content`=url) — client'ın AYRICA bir reveal çağrısı atmasına
     gerek YOK.
  6. `chat-image`'e ayrıca `activeTier` kontrolü eklendi (Pro/Pro+ değil,
     "herhangi bir abonelik" — ses tarafında zaten vardı, foto'da hiç
     yoktu, sunucu tarafında bypass edilebilirdi).

- Client (`ChatViewModel.swift`, `ChatService.swift`, `VoicePlayer.swift`):
  `appendPendingImageBubble`/`appendPendingVoiceBubble` create çağrısına
  `clientRequestId` eklendi; `generatePendingImage`/`generatePendingVoice`
  artık reveal çağrısı YAPMIYOR (server finalize ediyor), sadece
  `generateChatImage`/`synthesizeVoiceMessage`'a `clientRequestId`
  geçiyor.

- **Geriye dönük uyumluluk:** `clientRequestId` HER YERDE opsiyonel.
  Eski build göndermezse: sunucu claim/finalize'ı atlar, `chat/index.ts`'in
  ESKİ `reveal=true` iki-adımlı yolu (bu oturumun daha önceki bir fix'i,
  content+FIFO eşleştirmeli) DOKUNULMADAN duruyor, eski client onu
  çağırmaya devam eder. **Test edilmedi ama kod seviyesinde iki yol da
  bağımsız/çakışmasız.**

### UX bug'ları (fix'lendi)

- **Arka plana alınca yanlış "okundu":** `ChatView` artık
  `@Environment(\.scenePhase)` izliyor, `.background`/`.inactive`'te
  `viewModel.isVisible = false`.
- **Sohbet temizlerken mesaj sızması:** `ChatViewModel.chatEpoch` sayacı
  eklendi, `clearChat()` artırıyor, `deliverSegments` başında kontrol
  ediyor — temizleme sırasında/öncesinde bekleyen bir cevap artık
  "temizlenmiş" sohbete sızmıyor.
- **Foto/ses isteği + metin gönderme çakışması:** `canSend`/`send()`
  artık `isAwaitingMediaBubble`'ı da kontrol ediyor.
- **Liste yenilemesinin sırasız Task'ları:** `ChatListView`
  `.task { } .onChange { Task { } }` yerine `.task(id: conversationsVersion)`
  — önceki Task otomatik iptal ediliyor.

### Bilerek DOKUNULMAYAN bulgu

- Proaktif mesajlarda (`NotificationDelegate.swift`) çift
  `conversationsVersion` artışı — incelendi, KASITLI (biri anlık local,
  biri sunucu yazması bittikten sonra kesin tazeleme). Kaldırmak yeni bir
  "liste sunucu yazmadan önce yenileniyor" riski açardı, dokunulmadı.

### Bilinen, TAM kapatılamayan uç durum

- Ses reveal'ında "zaten tamamlanmış" idempotent retry cevabı BOŞ audio
  body döner (X-Voice-Url header'ı dolu ama body yok) — client bunu
  `.failure` olarak yorumlar (hata gösterir), AMA çift ücret YOK ve içerik
  sunucuda kalıcı zaten var (chate tekrar girince doğru görünür). Foto
  tarafında bu tam çözüldü (idempotent retry gerçek `url` JSON'la döner).

## 8. Deploy durumu

Tüm edge function değişiklikleri **Supabase CLI ile disk'ten** deploy
edildi (`npx supabase functions deploy <fn> --project-ref
ohpvhgwjmrfjclnumgnm`) — elle JSON payload yazmaktan kaçınıldı (bir kez
yanlışlıkla placeholder içerik deploy edilmişti, hemen düzeltildi, ders
çıkarıldı). Deploy edilenler: `chat`, `chat-image`, `voice-message-tts`.
Hepsi OPTIONS health-check ile doğrulandı (200).

DB migration (`client_request_id uuid` kolonu + index) doğrudan SQL ile
uygulandı, kod tabanında migration dosyası OLARAK YOK — birisi
`supabase/migrations/`'a taşımak isterse elle eklemesi lazım:

```sql
alter table messages add column if not exists client_request_id uuid;
create index if not exists messages_client_request_id_idx
  on messages(conversation_id, client_request_id)
  where client_request_id is not null;
```

## 9. Test edilmedi / doğrulanmadı

- Yukarıdaki fix'lerin HİÇBİRİ gerçek cihazda/simülatörde çalıştırılıp
  elle test edilmedi (bu ortamda Xcode yok). Statik kod incelemesi +
  edge function health-check + (bazı yerlerde) gerçek DB sorgusuyla
  doğrulandı, ama gerçek build almadan "çalışıyor" garantisi verilemez.
- Ses reveal'ının idempotent-retry dalı (yukarıdaki bilinen uç durum)
  özellikle test edilmeli.

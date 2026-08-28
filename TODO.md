# Plumm — Yapılacaklar

> **KURAL:** Bu dosyaya SADECE bitmemiş işler ve ileride yapılması konuşulmuş
> ama henüz yapılmamış şeyler yazılır. Biten bir iş buraya "çözüldü" diye
> eklenmez — tamamlanınca bu dosyadan tamamen silinir (git geçmişi + commit
> mesajları zaten kayıt tutuyor). Yeni bir oturum bu dosyayı güncellerken aynı
> kuralı uygular: önce ne bittiğini kontrol et, bitenleri buradan çıkar, sadece
> gerçekten açık kalanları/gündeme gelip ertelenenleri bırak.

Son güncelleme: 2026-08-28.

---

## 🔴 Tıkanıklar (dış sır/onay gerekiyor, ben çözemem)

### 1. Paid Applications Agreement — App Store submission'ın önündeki tıkaç
Durum bilinmiyor — ASC API bu alanı okutmuyor, Dashboard'dan elle bakılmalı:
https://appstoreconnect.apple.com/agreements/business/wwdr/YBC29RM673
`Active` olmadan StoreKit hiçbir IAP döndürmez, gerçek satın alma test edilemez.
Bugüne kadar: banka bilgisi girildi (İş Bankası — Apple'ın TR ödeme dizininde
yok, bu yüzden Garanti/Ziraat gibi bir banka gerekebilir), tax formları
gönderildi.

### 2. Sesli arama bağlanmıyor
`voice-call-start`'ın 4. adımı (ElevenLabs conversation token) 502 ile
patlıyor. Karakterlerin `voice_id`'siyle ilgisi yok — token isteği sadece
agent ID + API key kullanıyor. Olasılıklar: agent silinmiş (404) / kota
bitmiş (429) / key geçersiz (401).
**Gereken:** `ELEVEN_LABS` secret'ının güncel/geçerli olduğunu doğrula, ya da:
```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "xi-api-key: KEY" \
  "https://api.elevenlabs.io/v1/convai/conversation/token?agent_id=agent_5701kyp1mydkfqnsfn9zw0c2jbqn"
```
Loglar: https://supabase.com/dashboard/project/ohpvhgwjmrfjclnumgnm/functions/voice-call-start/logs

### 3. Silinmiş ElevenLabs sesi var mı — bilinmiyor
Ses havuzlarındaki (`elevenVoiceMap.ts`) ~22 ses ID'sinin hesapta hâlâ var
olup olmadığı doğrulanmadı. Hazır script: `scratchpad/check_voices.sh`
(`ELEVEN_LABS=<key> ./check_voices.sh`).

---

## 🟡 Karar/onay bekleyen (kullanıcıdan netleştirme gerekiyor)

### 4. Sohbet içi fotoğraf üretimi şu an KASITLI kapalı
`chat-image/index.ts` xAI/Civitai ile YENİ fotoğraf üretmiyor — sadece dev'in
önceden yüklediği küratörlü foto havuzundan (`character_photos`, `user_id
null`) seçim yapıyor; havuzda uygun/hiç foto yoksa `no_photo_available` (422)
hatası dönüyor. Koddaki elaborate prompt-üretim/xAI-Civitai çağrı mantığının
tamamı şu an **ölü kod** — hiç çalışmıyor. Yorum satırında "kullanıcı talebi"
diye not düşülmüş ama ne zaman/neden kapatıldığı belirsiz.
**Karar gerekiyor:** AI ile canlı üretime geri mi dönülsün, yoksa küratörlü-
havuz-only mimari kalıcı mı olsun? Kalıcıysa: her karakter için yeterli
küratörlü foto havuzu var mı kontrol edilmeli (yoksa boş havuzlu karakterler
hiç foto gönderemiyor).

### 5. `USE_CIVITAI_FOR_TESTING = true` — chat-image hâlâ TEMP test modunda
`chat-image/index.ts`'te Civitai/Flux2 Klein'a geçiş "2026-07-12 TEMP TESTING"
notuyla yapılmış, kalıcı değil. Madde 4'teki kararla birlikte ele alınmalı:
xAI Grok Imagine'e mi dönülsün, Civitai mi kalıcılaşsın (LoRA eğitimi vb. için
bkz. mevcut proje notları — Civitai LoRA eğitimi ayrıca bloklu).

### 6. Netleştirilmesi gereken 2 eski soru (hâlâ cevapsız)
- **Sihirbaz Step 5 "4 tip aynı fotoğraf"**: vibe adımı 4 seçenekli
  (Elegant/Energetic/Mysterious/Sweet), 4 asset dosyası byte olarak farklı
  ama görsel olarak birbirine çok benziyor olabilir. Hangi ekran/asset
  kastediliyor, kontrol edilmeli.
- **Galeri "Photos" başlığı**: kodda tek başına `"Photos"` literal'i yok,
  `GalleryView:123` `"Your Photos"` var. Hangi ekranda "Photos" görünüyor?

---

## 🟢 Yapılacak iş (tıkanık değil, netleşmiş)

### 7. TR App Store screenshot'ları eksik
ASC'de sadece `en-US` screenshot seti var. Yeni eklenen `tr` locale (isim/
açıklama/anahtar kelime metinleri girildi) kendi screenshot setine sahip
olmadan submit edilemez. EN görsellerin aynısı TR için de yüklenmeli —
yerelde screenshot dosyası yok, ayrıca üretilmeli/çekilmeli.

### 8. Token store screenshot'ı yanlış paketleri gösteriyor
Yüklenen görselde `100, 250, 500, 1000, 5000, 10000` var. Gerçek ürünler
`100/250/500/1000/2000/5000` (`token_2000` görselde yok, olmayan `10000`
paketi görünüyor). Build 4+ ile yeniden çekilip 6 ürüne yeniden yüklenmeli.

### 9. App Store version 1.0 hâlâ `PREPARE_FOR_SUBMISSION`
Madde 1 çözülüp Paid Agreement `Active` olduktan sonra ASC'den Submit
gerekiyor — 15 IAP ürünü `READY_TO_SUBMIT` olduğu için o gönderiye dahil
edilir. Madde 7 (TR screenshot) de bundan önce tamamlanmalı.

### 10. 3 boş review submission duruyor
`719dfed8`, `4c7e70d1`, `e2865819` — hepsi `READY_FOR_REVIEW`, item sayısı 0.
ASC arayüzünden elle temizlenebilir.

### 11. Ses seçimi — kalan küçük parçalar
- `docs/VOICE_SELECTION.md` hâlâ yazılmadı (yeni karakter eklerken ses
  seçiminin nasıl yapılacağını anlatan doküman, ileride başka ajanlar için).
- Ses havuzları ElevenLabs Voice Library'den romantik/anlatıcı seslerle
  genişletilebilir (madde 3'teki doğrulamaya bağlı).
- Haruka tek başına kurumsal bir seste (`Miss B. — Authoritative`),
  değiştirilmeli.
- `voice-message-tts` karakter id'si/seed almıyor (client bunu göndermiyor) —
  şu an düşük öncelikli çünkü tüm karakterlerde `voice_id` dolu (fallback
  path zaten tetiklenmiyor), ama ileride client wire-format'ı güncellenirse
  tamamlanabilir.

### 12. Sesli arama ücretlendirmesi bağlanmayan aramayı da faturalıyor
`voice-call-end` duvar saati süresinden hesaplıyor; hiç konuşulmayan bir
arama için bile ücret düşebiliyor. Kullanıcı "token muhabbeti aynı kalsın,
çok önemli değil" demişti — düşük öncelik.

### 13. Sihirbaz vibe listesi ile veri uyuşmuyor (kozmetik)
Sihirbaz 4 vibe sunuyor (Elegant/Energetic/Mysterious/Sweet), DB'de LLM
üretimi ~20 farklı vibe var. Ses haritası vibe'ı opsiyonel yaptığı için
artık kırılmıyor ama taksonomi ikiliği duruyor.

---

## Faydalı bilgiler (bir daha aramamak için)

- ASC app id `6794661721`, bundle `com.firat.Plumm`, team `YBC29RM673`
- ASC API key: `~/Downloads/AuthKey_72VZJFJ9JY.p8` (key `72VZJFJ9JY`,
  issuer `68f0580f-99da-480a-a4c1-46acfd3b4a74`) — çalıştığı doğrulandı.
  Yardımcı script: `scratchpad/asc.py` (JWT + GET/POST).
- Supabase proje `ohpvhgwjmrfjclnumgnm` ("AI Girlfriend"). **CLI artık
  kullanılabilir** — sistemde kurulu değil ama `npx -y supabase <komut>`
  çalışıyor ve keychain'de zaten authenticate + proje `link`li
  (`supabase/.temp/project-ref`). Edge function deploy'ları için MCP
  tool yerine `npx -y supabase functions deploy <fn> --project-ref
  ohpvhgwjmrfjclnumgnm` tercih edilmeli — büyük dosyalarda elle
  kopyalamaktan çok daha güvenilir (yerelden okuyor, retyping riski yok).
- RevenueCat proje `proj38579ac3` ("Plumm"), app `app340215e7c3`. v2 API
  secret key gerekiyor (v1 legacy key kabul etmiyor).
- Beta grup "Testers" internal — build'leri otomatik alır, elle atanamaz (422)
- IAP review screenshot: 1170x2532 kabul edildi, 1080x2532 edilmedi

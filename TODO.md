# Plumm — Yapılacaklar / Yarım Kalanlar

Son güncelleme: 2026-08-28. Bu dosya 2026-08-27/28 gecesi yapılan oturumun
çıktısı. Amaç: hangi hata çözüldü, hangisi çözülmedi, çözülmeyenin tam sebebi
ve neyle tıkandığı — tahmin bırakmadan.

Bağlam notu: `2c6185b` ile UI **zorla İngilizce**ye sabitlendi
(`PlummApp.swift:30` → `AppleLanguages=["en"]`, `.environment(\.locale, "en")`).
Bu, aşağıdaki lokalizasyon maddelerinin yönünü tersine çeviriyor: artık sorun
"İngilizce UI" değil, **İngilizce UI içinde görünen Türkçe veri**.

---

## ✅ ÇÖZÜLDÜ

### App Store Connect — ürünler
- [x] 6 token paketine review screenshot yüklendi (1170x2532, alpha'sız, hepsi `COMPLETE`).
      1080x2532 olan kaynak görsel satır bazlı kenar uzatmayla padlendi.
- [x] 6 token paketine USD base fiyat girildi ($1.99 / 3.99 / 6.99 / 11.99 / 19.99 / 39.99),
      175 ülkeye otomatik yayıldı. Öncesinde `manualPrices` ve `automaticPrices` boştu →
      StoreKit fiyatsız ürünü hiç döndürmez.
- [x] `token_250` — hiç localization'ı yoktu, eklendi.
- [x] `token_5000` — hiç `inAppPurchaseAvailability` kaydı yoktu, diğerlerinden 175 ülke kopyalandı.
- [x] 15 ürünün tamamına okunabilir EN + TR ad/açıklama yazıldı (önce hepsi ham product ID'ydi).
      Karakter limitleri (ad 30 / açıklama 45) yazmadan önce doğrulandı.
- [x] İki abonelikte yanlış tier adı vardı (`monthly_pro_normal` → "monthly_pro_plus",
      `yearly_pro_plus` → "yearly_pro_max"). Aynı grupta mükerrer görünen ad somut ret
      sebebidir; düzeltildi, artık mükerrer yok.
- [x] 15 ürün de `READY_TO_SUBMIT`.

### Product ID uyuşmazlığı
- [x] `monthly_pro_default` → `monthly_pro_normal` (`PurchaseService.swift`,
      `_shared/subscriptionSync.ts`, `Plumm.storekit`). ASC'de product ID
      değiştirilemez, düzeltilecek taraf koddu. Bu sadece "fetch edilemiyor"
      değildi: gerçek bir aylık Pro satın alması `tier=.none`, `tokens=0`
      alacaktı — para ödeyen kullanıcı hiçbir şey almaz.
- [x] RevenueCat: `monthly_pro_normal` ürünü oluşturuldu (`prod89bd9d3596`),
      `default` offering'in `$rc_monthly` paketine bağlandı, eski ürün arşivlendi.
      (Dashboard'da display name "monthly_pro_normal" yazıyordu ama gerçek
      `store_identifier` `monthly_pro_default`'tu — o yüzden gözden kaçmış.)
- [x] RevenueCat: `pro` / `pro_plus` / `max` entitlement'ları **hiç yoktu**, oluşturuldu
      ve 9 abonelik `PlummCatalog.productTier` eşlemesine göre bağlandı.
      Öncesinde `refreshEntitlement()` üç lookup'ta da nil alıp koşulsuz
      `tier = .none` yazıyordu → `refreshServerTier()` ile yarışıp ödeme yapmış
      kullanıcıyı non-Pro'ya düşürüyordu.
      Tier isimleri 4 yerde tutarlı doğrulandı: RC entitlement lookup_key,
      `subscriptionSync.ts PRODUCT_TIER`, `006_token_system.sql:30` check
      constraint, `refreshServerTier()` switch.

### TestFlight
- [x] Build 3 ve build 4 archive + export + validate + upload edildi, export
      compliance (`usesNonExemptEncryption=false`) verildi, ikisi de
      `IN_BETA_TESTING`, "Testers" grubuna otomatik girdi, testçiye bildirim gitti.
- [x] `CURRENT_PROJECT_VERSION` repoda 1'de kalmıştı (TestFlight'ta çoktan build 2
      vardı) → 3, sonra 4 yapıldı ve commit'lendi.
- [x] Şemaya `StoreKitConfigurationFileReference` geri konuldu (Debug'da ürünler
      yerel `Plumm.storekit`'ten okunsun). `Debug → Release` flip'i bilinçli
      olarak geri alınmadı — DEBUG bloklarını derlemeden çıkarırdı.

### Supabase
- [x] `sync-subscription` v14 → v15, `revenuecat-webhook` v6 → v7 deploy edildi.
      `verify_jwt` ayarları korundu (webhook `false` olmalı, RC'nin JWT'si yok —
      varsayılanla deploy etmek webhook'u kırardı).
- [x] `e34ccd8a-2608-40cf-85a6-a476e528e4be` hesabına `max` aboneliği verildi
      (2026-08-27 → 2027-08-27). Bakiyeye dokunulmadı.

### UI
- [x] Profildeki ilk ilgi alanı çipi `highlighted: idx == 0` ile "seçili" gibi
      görünüyordu; o ekranda ilgi alanları salt okunur. Hepsi aynı görünüyor artık.
- [x] Ex-history adımındaki Skip butonu sadece 13pt metin kadar tıklanabilirdi
      (Apple asgarisi 44x44pt). 44pt + `contentShape` + accessibility label.

### Ses seçimi
- [x] `_shared/elevenVoiceMap.ts` yeniden yazıldı. Eski tablo `role_vibe` anahtarlıydı
      ve taksonomi tamamen kaymıştı: 7 rolünden 4'ü (crazy/distant/ex/shy) artık
      üretilmiyor, DB'nin 7 rolünden 4'ü (bratty/confident/mysterious/sweet)
      haritada yoktu, vibe 4'ten 20'ye çıkmıştı. Ölçülen sonuç: `voice_id` NULL olan
      **15 karakterin tamamı** DEFAULT sese (Luna) düşüyordu — 15 karakter aynı sesle
      konuşuyordu. Yeni tasarım: anahtar ROL (kapalı küme), vibe opsiyonel ince ayar,
      her rolün 3-4 sesli havuzu, deterministik FNV-1a seçim (Math.random YOK).
      Kurumsal/"çağrı merkezi" tonundaki 6 ses `EXCLUDED`'a alındı.

---

## ❌ ÇÖZÜLMEDİ — TIKANIKLAR (sır/secret gerekiyor)

### 1. Paid Applications Agreement — HER ŞEYİN ÖNÜNDEKİ TIKAÇ
Durum: "Pending User Info". Tax formları gönderilmiş, banka bilgisi 2026-08-28'de
girildi, `Active`'e dönmesi bekleniyor (genelde birkaç saat, bazen 24-48 saat).

**Agreement `Active` olmadan StoreKit hiçbir IAP döndürmez.** Yani yukarıda
düzeltilen product ID / fiyat / entitlement işlerinin hiçbiri TestFlight'ta
görünmez ve RevenueCat "none of the products could be fetched" hatası devam eder.
Test etmeden önce Agreements sayfasında `Active` yazdığını gör.

Not: İş Bankası Apple'ın Türkiye ödeme dizininde **yok** (Garanti/Ziraat var).
IBAN geçerliydi (mod-97 doğrulandı, banka kodu 00064), sorun dizinde olmamasıydı.

ASC API'de agreement durumu okunabilen bir alan değil → otomatik izlenemiyor.

### 2. Sesli arama bağlanmıyor
`voice-call-start` akışının ilk 3 adımı geçiyor (entitlement ✓, xAI ilk mesaj ✓,
`call_sessions` satırı ✓), **4. adım patlıyor**: ElevenLabs conversation token.

Kanıt: 22:00:13→22:00:21 session'ı `tokens_charged: 0` + anında `ended` — bu tam
olarak `voice-call-start:280-287`'deki `elevenlabs_token_failed` rollback yolu (502).
Her iki denemede de `call_turns` = 0, `last_checkpoint_seconds` = 0.

Karakterlerin `voice_id`'siyle **ilgisi yok** — token isteği sadece agent ID + API
key kullanıyor.

Olasılıklar: agent silinmiş (404) / kota bitmiş (429) / key geçersiz (401).
Agent ID kodda hardcoded: `voice-call-start:39` →
`agent_5701kyp1mydkfqnsfn9zw0c2jbqn`. 18 secret listelendi, `ELEVENLABS_AGENT_ID`
yok (kodda notu var: CLI hesabı org Owner olmadığı için `supabase secrets set` bloklu).

**Gereken:** `ELEVEN_LABS` secret'ı, ya da şu komutun çıktısı:
```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "xi-api-key: KEY" \
  "https://api.elevenlabs.io/v1/convai/conversation/token?agent_id=agent_5701kyp1mydkfqnsfn9zw0c2jbqn"
```
Ya da: https://supabase.com/dashboard/project/ohpvhgwjmrfjclnumgnm/functions/voice-call-start/logs

### 3. xAI görsel üretimi çalışmıyor — GENEL
Sadece karakter oluşturmada değil. Veritabanı kanıtı:
```
2026-08-27 22:27  image_pending  → tamamlayan "image" satırı YOK
2026-08-26 12:55  image_pending  → tamamlayan "image" satırı YOK
son gerçek üretim: 2026-07-22 (Alev)
```
Aradaki `image` satırlarının URL'leri `/curated/...` — hazır fotoğraflar, üretim değil.

Hipotez: `grok-imagine-image` da retire edilmiş (metin modeli
`grok-4-1-fast-non-reasoning` 2026-05-15'te retire edilmişti).

**Gereken:** `XAI_API_KEY`, ya da `create-character` / `chat-image` fonksiyon logları.

### 4. Silinmiş ElevenLabs sesi var mı — bilinmiyor
33 benzersiz voice ID (28 harita + 5 karaktere özel) ElevenLabs hesabında hâlâ
var mı kontrol edilemedi. Hazır script:
`scratchpad/check_voices.sh` (`ELEVEN_LABS=<key> ./check_voices.sh`).
Yeni ses havuzları bu doğrulama yapılmadan kesinleşmiş sayılmamalı.

---

## ❌ ÇÖZÜLMEDİ — YAPILACAK İŞ (tıkanık değil)

### 5. Token store screenshot'ı yanlış paketleri gösteriyor
Yüklenen görselde `100, 250, 500, 1000, 5000, 10000` var. Gerçek ürünler
`100/250/500/1000/2000/5000`. Yani **`token_2000` kendi review screenshot'ında
görünmüyor** ve hiç var olmayan bir `10000` paketi görünüyor. Görsel eski bir
build'den; içindeki ₺ fiyatlar da girilen USD fiyatlarla uyuşmuyor.
→ Build 4+ ile yeniden çekilecek (kullanıcı halledecek), sonra 6 ürüne yeniden yüklenecek.

### 6. App Store version 1.0 gönderi kuyruğundan çıktı
Abonelik isimlerinin kilidini açmak için bekleyen review submission item'ları
silindi (kullanıcı onayıyla, appStoreVersion dahil). Sonuç: 1.0
`READY_FOR_REVIEW` → **`PREPARE_FOR_SUBMISSION`**. Review'a hazır olunca ASC'den
tekrar Submit gerekiyor; 15 ürün `READY_TO_SUBMIT` olduğu için o gönderiye dahil edilir.

### 7. 3 boş review submission duruyor
`719dfed8`, `4c7e70d1`, `e2865819` — hepsi `READY_FOR_REVIEW`, item sayısı 0.
ASC arayüzünden temizlenebilir.

### 8. Retired xAI metin modeli 12 fonksiyonda duruyor
`grok-4-1-fast-non-reasoning`, xAI 2026-05-15'te retire etti. `33147d8` sadece
`chat/index.ts`'i `grok-4.3`'e pinledi. Kalanlar:
`voice-call-start:33`, `voice-call-end:20`, `voice-call-llm-webhook:20`,
`character-schedule:21`, `chat-image:28`, `dev-create-character:32`,
`generate:17`, `chat-image-civitai-test:28`, `create-character:34`,
`validate-history:15`, `_shared/tagline-i18n.ts:16`.
Şu an legacy redirect sayesinde çalışıyorlar; xAI redirect'i kaldırdığı gün 12'si
birden düşer. (Sesli aramanın şu anki arızası bu DEĞİL — `generateFirstMessage`
session insert'inden önce çalışıyor, patlasaydı satır hiç oluşmazdı.)

### 9. Ses seçimi — yarım kalanlar
Yeni `elevenVoiceMap.ts` yazıldı ama:
- [ ] `pickVoiceIdForNewCharacter` **hiçbir yere bağlı değil**.
      `create-character/index.ts:324` ve `dev-create-character/index.ts:182`
      insert'lerinde `voice_id` set edilmiyor → yeni karakterler NULL geliyor
      (Astra öyle geldi). Kullanıcı talebi: "yeni karakter oluşturulduğunda
      otomatik ses atanmalı (user'a sormadan)".
      Yapılacak: aynı role sahip mevcut karakterlerin `voice_id`'lerini çek,
      `pickVoiceIdForNewCharacter(role, vibe, usedInRole, seed)` ile en az
      kullanılanı seç, insert'e ekle.
- [ ] `voice_id` NULL olan 15 karakter backfill edilmedi:
      Yuzuki, Freya, Wren, Selin, Priya, Odette, Zara, Mei, Ingeborg, Camila,
      Saoirse, Amara, Kohaku, Kaede, Mizuki (+ Astra = 16).
- [ ] `docs/VOICE_SELECTION.md` yazılmadı — kullanıcı talebi: yeni karakter
      eklerken ses seçiminin nasıl yapılacağını anlatan, ileride başka ajanların
      bakacağı doküman. İlke: sadece hikâye anlatımı / romantik / sıcak tonlar,
      çağrı merkezi / eğitmen / kurumsal sesler `EXCLUDED`'a.
- [ ] Havuzlar ElevenLabs Voice Library'den romantik/anlatıcı seslerle
      genişletilecek (madde 4'e bağlı).
- [ ] Haruka tek başına kurumsal bir seste (`Miss B. — Authoritative`), değiştirilmeli.
- [ ] `elevenVoiceIdFor` çağrılarına `seed` (karakter id) geçirilmiyor —
      `voice-call-start:265` characterId'ye sahip, verilebilir.
      `voice-message-tts` karakter id'si almıyor, istemcinin göndermesi gerekir.

### 10. Görsel üretimi başarısız olunca karakter yine oluşuyor
`CreateCharacterView.reveal()` → `generatePhoto()` nil dönse bile
`await createCharacter()` çalışıyor (kodda "her durumda karakteri oluştur" notu).
Sonuç: `photo_url = NULL` satır, blur kalkınca altındaki **dummy vibe fotosu**
görünüyor (kullanıcının gördüğü tam bu) ve **50 coin de düşüyor**.
Astra: `photo_url`, `avatar_url` NULL, `gallery_urls` [], `character_photos` boş.
→ Üretim başarısızsa oluşturmayı iptal et, coin düşme, kullanıcıya net hata göster.

### 11. İngilizce UI içinde Türkçe VERİ (ölçüldü)
42 karakterden:
- **18'inin mesleği Türkçe**: Wren, Sakura, Vix, Kohaku, Freya, Kaede, Hana,
  Mizuki, Ingeborg, Mei, Saoirse, Amara, Ingrid, Priya, Yuzuki, Odette, Camila, Luna
  (`Sanat öğrencisi`, `Hemşire`, `Fal bakıcısı`, `Bale eğitmeni`…)
- 2'sinin ilgi alanları Türkçe: Astra, Alev
- 1'inin tagline'ı Türkçe: Astra (ama `tagline_i18n.en` 42/42 karakterde var)

Ek olarak sihirbazdaki hobi listesi **hardcoded Türkçe**
(`CreateCharacterView.swift:184` → `"🎵 Müzik", "🎬 Sinema", "✈️ Seyahat"…`) ve
`Text(hobby)` ham string basıyor. Yani sihirbazla oluşturulan her karakter
Türkçe ilgi alanı alıyor.

### 12. `localizedTagline` İngilizce zorlamasını görmüyor
`Character.swift:171-174` → `Locale.current.language.languageCode`.
`2c6185b`'nin zorlaması `AppleLanguages` UserDefaults'unu ve SwiftUI
`.environment(\.locale)`'ı değiştiriyor, **`Locale.current`'ı kontrol etmiyor**.
Sonuç: Türk cihazda UI İngilizce ama tagline Türkçe dönebilir.
→ `localizedTagline` sabit "en" kullanmalı ya da tek bir dil kaynağından okumalı.

### 13. Profilde meslek lokalize olmuyor (kod hatası)
`CharacterProfileView.swift:341-342` → `Text(profession)`. SwiftUI yalnızca
string **literal**'lerini otomatik lokalize eder; değişken hiçbir zaman kataloğa
bakmaz. Sihirbazın 12 mesleği katalogda çevrili (`Student` → `tr='Öğrenci'`),
ama profilde her zaman ham DB değeri görünüyor.
→ Bilinen 12 id için lookup, serbest metinler için madde 14.

### 14. `profession_i18n` / `interests_i18n` yok
Meslek 41 farklı serbest değer, ilgi alanları 178 farklı serbest değer — ikisi de
LLM üretimi, katalog key'i değil. String kataloğuyla çözülemez.
→ `tagline_i18n` ile aynı desen: migration + oluşturma anında
`_shared/tagline-i18n.ts` üzerinden çeviri + mevcut 42 karakter için backfill.

### 15. Sesli arama ücretlendirmesi bağlanmayan aramayı da faturalıyor
21:58 session'ı: `call_turns` 0, `last_checkpoint_seconds` 0, ama
`tokens_charged: 65`. `voice-call-end` duvar saati süresinden hesaplıyor.
Kullanıcı hiç konuşmadığı arama için ödüyor.
(Kullanıcı "token muhabbeti birebir aynı kalsın, çok önemli değil" dedi — düşük öncelik.)

### 16. Lokalizasyon kapsamı — karar gerekiyor
`Localizable.xcstrings` (merge sonrası yeniden ölçülmeli): merge sonrası ölçüm:
`tr 460/1213 (%37)`, diğer 5 dil `%33`, 753 key’in Türkçesi yok.
UI artık zorla İngilizce olduğu için bu **şu an müşteriye görünmüyor**.
Karar: çok dilli desteğe dönülecek mi, yoksa İngilizce-only mi kalınacak?
İngilizce-only kalınacaksa madde 11/12/13/14 (Türkçe veri) asıl iş, katalog değil.

### 17. Netleştirilmesi gerekenler (kullanıcıdan)
- **Step 5 "4 tip aynı fotoğraf"**: vibe adımı 4 seçenekli
  (Elegant/Energetic/Mysterious/Sweet). Koddaki eşleme doğru, 4 asset dosyası
  byte olarak farklı (MD5'leri ayrı). Ya 4 fotoğraf gerçekten birbirine benziyor
  (görsel varlık sorunu) ya da kastedilen başka bir adım. → Hangisi?
- **Galeri "Photos" başlığı**: kodda tek başına `"Photos"` literal'i yok.
  `GalleryView:123` `Text("Your Photos")` ve onun Türkçesi mevcut. "Photos" key'i
  katalogda hiç yok. → Hangi ekran?

### 18. RevenueCat temizliği (kozmetik)
6 ölü inactive ürün: `weekly_pro` ×2, `yearly_pro`, `yearly_pro_2` ×2, ve yazım
hatalı `yeraly_pro_2`. Zararsız, arşivlenebilir.

### 19. Sihirbaz vibe listesi ile veri uyuşmuyor
Sihirbaz 4 vibe sunuyor (Elegant/Energetic/Mysterious/Sweet), DB'de LLM üretimi
20 farklı vibe var. Yeni ses haritası vibe'ı opsiyonel yaptığı için artık
kırılmıyor, ama taksonomi ikiliği duruyor.

---

## Faydalı bilgiler (bir daha aramamak için)

- ASC app id `6794661721`, bundle `com.firat.Plumm`, team `YBC29RM673`
- ASC API key: `~/.appstoreconnect/private_keys/AuthKey_72VZJFJ9JY.p8`,
  issuer `68f0580f-99da-480a-a4c1-46acfd3b4a74`
- Supabase proje `ohpvhgwjmrfjclnumgnm` ("AI Girlfriend"), CLI bu makinede kurulu
  değil — binary indirilebilir, kimlik keychain'de ("Supabase CLI")
- `supabase projects api-keys --project-ref ...` service_role key'i verir
- RevenueCat proje `proj38579ac3` ("Plumm"), app `app340215e7c3`.
  v1 legacy key v2 API'yi kabul etmez, v2 secret key gerekir
- Beta grup "Testers" internal — build'leri otomatik alır, elle atanamaz (422)
- IAP review screenshot: 1170x2532 kabul edildi, 1080x2532 edilmedi

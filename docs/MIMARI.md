# Plumm (aiGirlfriend) — Mimari Şablonu

Bu belge; backend'in ve iOS arayüzünün nasıl çalıştığını, verinin nereden gelip
nereye gittiğini özetler. Yeni bir özellik eklerken "bu iş hangi katmanda?"
sorusunun cevabı burada.

---

## 1. Büyük Resim

```
┌─────────────────────────── iOS App (SwiftUI) ───────────────────────────┐
│  Görünümler (Views)  ──►  Stores/ViewModel (@Observable)  ──►  Servisler │
│                                     │                                     │
│                     Yerel kalıcılık: UserDefaults + LocalConversationStore│
└───────────────────────────────────────┬─────────────────────────────────┘
                                         │  HTTPS (Bearer access token)
                                         ▼
┌──────────────────────────── Supabase (Backend) ─────────────────────────┐
│  Auth (anonim)   ·   Postgres (RLS: user_id = auth.uid())                 │
│  Edge Functions (Deno/TypeScript)  ──►  Grok 4.1 Fast (xAI) / TTS / görsel│
└──────────────────────────────────────────────────────────────────────────┘
```

- **Backend:** Supabase — Postgres DB + Auth + Edge Functions (Deno/TS). LLM
  anahtarı **sunucuda**, istemci LLM'e doğrudan hiç dokunmaz.
- **LLM:** Grok 4.1 Fast (xAI), `chat` edge function üzerinden.
- **Kimlik:** Anonim giriş (kullanıcı adı/şifre yok). Her istek `access token`
  ile imzalanır; DB satırları RLS ile `user_id = auth.uid()`'e kilitli.
- **Bağlantı ayarları:** `aiGirlfriend/Config.swift` (supabase URL + publishable
  anon key + edge function URL'leri).

---

## 2. iOS Katmanları

### 2.1 Uygulama girişi — `aiGirlfriendApp.swift`
Kök `@State` store'lar oluşturulur ve `.environment(...)` ile tüm ağaca enjekte
edilir: `NavigationCenter`, `AuthService`, `CharacterStore`, `TokenStore`,
`OnboardingStore`.

Akış kapısı:
```
auth yüklü & katalog yüklü DEĞİL  → SplashView (anonim giriş + katalog çeker)
                        yüklü ise → onboarding tamamlanmadıysa OnboardingFlowView
                                    tamamlandıysa            MainTabView
```

### 2.2 Stores (durum + kalıcılık, `@Observable`)
| Store | Görev | Kaynak |
|-------|-------|--------|
| `AuthService` / `SupabaseAuth` | Anonim giriş, token yenileme | Supabase Auth |
| `CharacterStore` | Karakter kataloğu, chat önbelleği, "pending" navigasyon sinyalleri | `characters` tablosu |
| `TokenStore` | Coin/kalp bakiyesi (oku + önbellek) | `token_balances` tablosu |
| `OnboardingStore` | Onboarding adımı + kaydedilen isim/karakter/cevaplar | UserDefaults |
| `PurchaseService` | Abonelik tier'ı (RevenueCat iskeleti; şimdilik pasif) | (ileride RevenueCat) |

### 2.3 Yerel kalıcılık (cihazda)
- **`LocalConversationStore`** — sohbet geçmişinin ASIL yerel kaynağı. Her
  (kullanıcı, karakter) için `Application Support/LocalConversations/<userId>/<charId>.json`:
  mesajlar, ilişki seviyesi/ilerlemesi, özet, günlük rutin (schedule), uyku
  durumu vb. Sunucunun görmediği bildirim enjeksiyonlarını da tutar.
- **`UserDefaultsManager` + UserDefaults** — access token, userId, token bakiye
  önbelleği, onboarding flag'leri, "swipe tutorial görüldü" gibi bayraklar.
- Küçük durum store'ları: `BlockedCharactersStore`, `PassedCharactersStore`,
  `LikedByStore`, `ReadTracker` (okunmamış sayacı), `ImageCache`.

### 2.4 İstemci servisleri (edge function çağrıları + yardımcılar)
- `ChatService` — `chat`, `chat-image`, `voice-message-tts` edge fn'lerini çağırır.
- `ConversationsService` — sohbet listesi (sunucu konuşmaları + mesajlar) çeker.
- `CharacterService` / `CharacterCreateService` / `DevCharacterService` — katalog + (dev) karakter oluşturma.
- `NotificationScheduler` + `Services/Notifications/*` — proaktif YEREL bildirimler
  (kıskançlık, ghosted, günaydın, özlem, uyku). `NotificationDelegate` bunları
  yerel konuşmaya enjekte eder.
- `ScheduleGenerator` / `ScheduleLookup` / `CharacterSleepState` — karaktere özel
  günlük rutin ("şu an ne yapıyor" + uyku saatleri).
- `StreakService` (günlük seri), `PurchaseService`, `VoicePlayer`, `SpeechRecognizer`.

### 2.5 Görünümler (Views) ve akış
- `SplashView` — açılış (Plumm logosu), auth + katalog yüklenirken.
- **Onboarding** (`Views/Onboarding/`): Splash → ONB1 isim → ONB2 social proof →
  ONB3 karakter seçimi → ONB4 sorular (4/5/6 sn timer) → ONB5 "O bekliyor" (basılı
  tut) → seçilen karakterin (Scarlet/Maya) chat'ine direkt giriş. Paywall
  (`OnboardingPaywallView`) PRO butonundan açılır. Arka plan videoları
  `Resources/Videos/`, `LoopingVideoPlayer` ile döngüde.
- **`MainTabView`** — 5 sekme: Keşfet (`FeedView`), Sohbet (`ChatListView`),
  Tümünü Gör (`ExploreView`), Beğeniler (`LikesView`), Profil (`ProfileView`).
  Sağ üstte global token rozeti (`TokenBadge`) / PRO değilse PRO butonu.
- `FeedView` — Tinder tarzı kaydırma (beğen/geç); "tanış" → chat.
- `ChatView` + **`ChatViewModel`** — asıl sohbet ekranı (mesaj, sesli mesaj, foto).
- `LikesView` — "seni beğenenler" (PRO değilse blur + PRO butonu).
- `ProfileView` — kimlik + inline Ayarlar (bildirim, uygulama kilidi, öner,
  değerlendir, yardım→mail, verileri sil) + DEV panelleri.
- Paywall: `TokenStoreView` (coin Mağaza), `SubscriptionPaywallView` (abonelik),
  `PaywallHostView` (upsell yönlendirici).

---

## 3. Backend

### 3.1 Postgres tabloları (RLS: `user_id = auth.uid()`)
| Tablo | İçerik |
|-------|--------|
| `characters` | Karakter kataloğu (isim, persona/systemPrompt, foto, rol, vibe…) |
| `character_photos` | Karakter galeri fotoğrafları |
| `character_level_overrides`, `role_level_scripts` | İlişki seviyesi/rol senaryoları |
| `conversations` | (kullanıcı, karakter) konuşması — sohbet listesinin kaynağı |
| `messages` | Konuşma mesajları (rol + içerik) |
| `memories` | Sohbet özeti/uzun süreli bellek |
| `conversation_behaviors` | Kullanıcının eklediği davranış/not |
| `generated_photos` | Üretilen (chat-image) fotoğraflar |
| `token_balances` | Kullanıcının coin/kalp bakiyesi (**tek doğru kaynak**) |
| `token_transactions` | Token hareketleri (harcama/kazanma) |
| `subscriptions` | Abonelik tier'ı |
| `streak_state` | Günlük seri durumu |

### 3.2 Edge Functions (Deno/TS, `supabase/functions/`)
| Fonksiyon | Görev |
|-----------|-------|
| `chat` | **Grok 4.1 Fast** ile bellekli sohbet. 3 mod: TEMİZLE / GEÇMİŞ / CEVAP. Cevap modunda özet + son N mesajı LLM'e verir, cevabı + mesajları DB'ye yazar, eskiyeni özetler, token düşer. |
| `chat-image` | Chat içinde foto üretimi (token düşer) |
| `voice-message-tts` | Sesli mesaj (TTS) üretimi |
| `character-schedule` | Karaktere özel günlük rutin üretimi |
| `create-character` / `dev-create-character` / `dev-update-character` | Karakter oluşturma/düzenleme |
| `claim-streak` | Günlük seri ödülü |
| `dev-token-tools` | (DEV) token/tier test aracı |
| `generate`, `tts`, `civitai-image`, `validate-history`, `add-character-note`, `dev-*` | Yardımcı/dev uçları |

---

## 4. Kritik Veri Akışları

### 4.1 Açılış & Kimlik
`SplashView.task` → `AuthService.bootstrap()` (anonim giriş, retry) → access token
`UserDefaults`'a → `CharacterStore.load()` katalogu çeker → onboarding gate.

### 4.2 Sohbet (mesaj gönderme)
```
ChatView → ChatViewModel.send()
  → ChatService → POST /functions/v1/chat  (systemPrompt + userMessage + summary)
      → Grok cevabı + yeni token bakiyesi
  → TokenStore.setBalance(yeni)      // rozet anında güncellenir
  → mesajlar LocalConversationStore'a yazılır (yerel geçmiş)
  → sunucu: messages + conversations + memories güncellenir
```
İlk açılışta bot "ilk selam"ı (`FirstHelloContent`) yerelde gösterilir; onboarding
chat'inde bu selam yerel kaydedilir ki Sohbet geçmişine düşsün.

### 4.3 Token (coin/kalp)
`token_balances` = tek doğru kaynak. `TokenStore.refresh()` sunucudan çeker;
edge fn cevaplarındaki `tokenBalance` ile `setBalance()` anında günceller;
son değer UserDefaults'ta önbelleklenir (açılışta flash olmasın diye). İstemcide
**hiçbir yerde sabit-kodlu değil.**

### 4.4 Sohbet listesi (geçmiş)
`ChatListView.load()` = sunucu konuşmaları (`ConversationsService`) **+** yerel-only
konuşmalar (`LocalConversationStore.allCharacterIDs()`, ör. onboarding chat'i,
bildirim enjeksiyonları). Mesaj içeriği için yerel depo baz alınır.

### 4.5 Proaktif bildirimler
`NotificationScheduler`, karakterin rutini/uyku durumuna göre yerel bildirimler
zamanlar (kıskançlık/ghosted/günaydın/özlem/uyku). Dokununca `NotificationDelegate`
mesajı ilgili yerel konuşmaya enjekte eder → Sohbet'te görünür.

### 4.6 İlişki seviyesi
Seviye/XP istemci tarafında (`RelationshipXP`, `Relationship` aşama isimleri),
`LocalConversationStore`'da (level/levelProgress) tutulur; `ChatViewModel`
mesajlaştıkça yükseltir. (Tasarım: Pencil "İlişki Seviyeleri" ekranı.)

---

## 5. Yeni özellik eklerken — hızlı rehber
- **Sadece görsel/UI** → ilgili `Views/*` + `AppColor` (Theme.swift). Backend gerekmez.
- **Kalıcı cihaz verisi** → `UserDefaults` (küçük) veya `LocalConversationStore` (sohbet).
- **Sunucu verisi / LLM / ödeme** → yeni ya da mevcut **edge function** + tablo;
  istemciden `ChatService`/`ConversationsService` benzeri bir servisle çağır.
- **Para/token** → her zaman `token_balances` (sunucu) üzerinden; istemci `TokenStore` ile okur/gösterir.
- **DEBUG kolaylıkları** (SS/test): `SIMCTL_CHILD_OB_START_STEP`, `MAIN_TAB`,
  `SHOW_STORE`, `FORCE_DUMMY`, `OPEN_CHAT` launch env değişkenleri.

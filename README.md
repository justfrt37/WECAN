# aiGirlfriend

AI arkadaş / companion iOS uygulaması.
**Yığın:** SwiftUI (iOS 17+) · Supabase (Free ile başla) · Grok 4.1 Fast (xAI).

## Mimari

```
[iOS App / SwiftUI]
       │  (Supabase anon key ile)
       ▼
[Supabase Edge Function: chat]  ◄── Grok API key BURADA gizli
       │
       ▼
[xAI Grok 4.1 Fast]   +   [Postgres + pgvector]  (geçmiş + uzun bellek)
```

Grok API key **hiçbir zaman uygulamanın içinde değil** — Edge Function'da (sunucuda) durur.

## Proje yapısı

```
aiGirlfriend.xcodeproj         Xcode projesi (synchronized folder)
aiGirlfriend/                  Swift kaynakları
  aiGirlfriendApp.swift        Giriş noktası
  Config.swift                 Supabase URL + anon key (DOLDUR)
  Models/                      Character, Message
  Services/ChatService.swift   Edge Function'ı çağırır
  ViewModels/ChatViewModel.swift
  Views/                       CharacterListView, ChatView, MessageBubble
supabase/
  schema.sql                   Tablolar + pgvector + RAG fonksiyonu
  functions/chat/index.ts      Grok 4.1 Fast çağıran Edge Function
```

## Kurulum

### 1. iOS uygulaması
- `aiGirlfriend.xcodeproj`'i Xcode ile aç, çalıştır (iOS 17+ simülatör).
- `Config.swift` içine Supabase `URL` ve `anon key`'i gir.

### 2. Supabase
1. [supabase.com](https://supabase.com) → yeni proje (Free).
2. SQL Editor → `supabase/schema.sql` içeriğini çalıştır.
3. Supabase CLI ile Edge Function'ı deploy et:
   ```bash
   supabase functions deploy chat
   supabase secrets set XAI_API_KEY=xai-...     # xAI key
   ```
   (Alternatif: OpenRouter — `index.ts` içindeki URL/MODEL'i değiştir,
   `OPENROUTER_API_KEY` secret'ı ekle. Model değişimi tek satır.)

### 3. Grok key
- [x.ai](https://x.ai/api) → API key al → yukarıdaki secret'a koy.

## Sonraki adımlar (roadmap)
- [ ] **Auth** (Supabase Auth — e-posta/Apple ile giriş)
- [ ] **Kalıcılık** — mesajları `messages` tablosuna yaz/oku
- [ ] **Katmanlı bellek (500 tur)** — Edge Function'da:
      son ~30 mesaj + eski turların özeti + pgvector RAG ile kalıcı anılar
- [ ] **Streaming** — token-token cevap (daha akıcı his)
- [ ] **Premium tier** — Grok 4.3'e yükselt
- [ ] **+18:** hacim büyüyünce **self-hosted Supabase**'e geç (politika + maliyet)

## Maliyet (başlangıç)
- Supabase: **Free $0** (geliştirme) → canlıda Pro $25/ay veya self-host VPS ~$10-20/ay
- Grok 4.1 Fast: **$0.20 / $0.50** (1M giriş/çıkış token) — kullanıcı başı ~$0.9/ay

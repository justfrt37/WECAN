# Clear Chat Selective-Keep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend "Clear Chat" (from `ChatView`'s gear menu) with a keep/wipe dialog for relationship level, memories, and behavior preferences, per `docs/superpowers/specs/2026-07-27-clear-chat-selective-keep-design.md`.

**Architecture:** Server-side (`chat/index.ts`), the hard-delete-the-whole-conversation-row approach is replaced with targeted deletes/updates on the existing row, conditioned on three new boolean flags in the request body. Client-side, three new optional parameters thread from a new `ClearChatOptionsSheet` view through `ChatViewModel.clearChat()` → `ChatMaintenance.clearChat()` → `ChatService.clearConversation()` → the wire request. `ChatListView`'s long-press entry point is untouched (still calls the same function with all three flags defaulted to `false`, i.e. today's full-wipe behavior).

**Tech Stack:** Deno edge function (backend), Swift/SwiftUI (client). No test suite for either side (same constraint as prior plans) — verification is `xcodebuild build` + deploy + manual smoke testing.

## Global Constraints

- Schedule (`schedule` column / `CharacterSchedule`) is NOT offered as a keep option — always reset (regenerated fresh on next open, per spec).
- `ghosted_at`, `woken_up_at`, `manual_sleep_at`, `detected_language` are always reset — ephemeral per-conversation state, not part of the keep-option list.
- Memories/behaviors are server-only tables — the client has no local copy of them, so `keepMemories`/`keepBehaviors` only affect the server call, not `LocalConversationStore`.
- `ChatListView`'s long-press "Clear Chat" (`aiGirlfriend/Views/ChatListView.swift:44` and `:290`) must keep compiling unchanged and behaving identically (full wipe, no dialog) — achieved via default parameter values of `false` on every new parameter added in this plan.
- Any OTHER duplicate `conversations` rows for the same (user, character) — the pre-existing dupe-cleanup case already handled by the current code — are still always hard-deleted regardless of the keep flags; keep options only apply to the primary row being cleared.

---

### Task 1: Server — rewrite the clear branch in `chat/index.ts`

**Files:**
- Modify: `supabase/functions/chat/index.ts:712-724`

**Interfaces:**
- Consumes: `body.clearConversation`, plus new `body.keepLevel`, `body.keepMemories`, `body.keepBehaviors` (all optional booleans, `undefined`/anything-but-`true` treated as `false`).
- Produces: nothing for later tasks — this is the server side of the contract Task 3 (client `ChatRequest`) must match field-for-field: `keepLevel`, `keepMemories`, `keepBehaviors`.

- [ ] **Step 1: Make the change**

Find:

```ts
    // === SOHBETİ TEMİZLE === İstemcinin "Clear Chat" eylemi — konuşma satırını
    // siler (messages/memories cascade ile birlikte gider), bir sonraki açılışta
    // sıfırdan (yeni bir "ilk selam" akışıyla) başlar.
    if (body.clearConversation === true) {
      // TÜM eşleşen conversation'ları sil (messages/memories cascade ile gider).
      // maybeSingle KULLANMA — aynı user+character için birden çok satır varsa
      // (eski dupe'lar) hata verip HİÇBİR ŞEY silmiyordu → mesajlar geri geliyordu.
      await db.from("conversations")
        .delete()
        .eq("user_id", uid)
        .eq("character_id", characterId);
      return json({ ok: true });
    }
```

Replace with:

```ts
    // === SOHBETİ TEMİZLE === İstemcinin "Clear Chat" eylemi. Eskiden satırın
    // TAMAMI silinirdi (messages/memories cascade ile) — artık isteğe bağlı
    // olarak relationship_level/level_progress, memories, ve
    // conversation_behaviors KORUNABİLİR (bkz. keepLevel/keepMemories/
    // keepBehaviors) — bu yüzden satırın kendisi artık SİLİNMİYOR, hedefli
    // delete/update yapılıyor. Mesajlar HER ZAMAN silinir; schedule/woken_up_at/
    // manual_sleep_at/ghosted_at/detected_language HER ZAMAN sıfırlanır (keep
    // seçeneği sunulmayan, geçici per-conversation durum alanları).
    if (body.clearConversation === true) {
      const keepLevel: boolean = body.keepLevel === true;
      const keepMemories: boolean = body.keepMemories === true;
      const keepBehaviors: boolean = body.keepBehaviors === true;

      // TÜM eşleşen conversation satırlarını bul (dupe'lar dahil) — en güncel
      // olan ASIL temizlenen satır, gerisi (eski dupe'lar) her zaman tamamen
      // silinir (keep seçenekleri sadece asıl satıra uygulanır).
      const { data: rows } = await db
        .from("conversations")
        .select("id")
        .eq("user_id", uid)
        .eq("character_id", characterId)
        .order("updated_at", { ascending: false });

      if (!rows || rows.length === 0) return json({ ok: true });

      const [primary, ...dupes] = rows;
      if (dupes.length > 0) {
        await db.from("conversations").delete().in("id", dupes.map((d) => d.id));
      }

      await db.from("messages").delete().eq("conversation_id", primary.id);
      if (!keepMemories) {
        await db.from("memories").delete().eq("conversation_id", primary.id);
      }
      if (!keepBehaviors) {
        await db.from("conversation_behaviors").delete().eq("conversation_id", primary.id);
      }

      const update: Record<string, unknown> = {
        summary: "",
        summarized_count: 0,
        schedule: null,
        woken_up_at: null,
        manual_sleep_at: null,
        ghosted_at: null,
        detected_language: null,
      };
      if (!keepLevel) {
        update.relationship_level = 1;
        update.level_progress = 0;
      }
      await db.from("conversations").update(update).eq("id", primary.id);

      return json({ ok: true });
    }
```

- [ ] **Step 2: Verify the diff**

Run: `git diff supabase/functions/chat/index.ts`
Expected: only the clear branch changed, nothing below it (the character/convoRows `Promise.all` from the backend-perf plan) touched.

- [ ] **Step 3: Commit**

```bash
git add supabase/functions/chat/index.ts
git commit -m "feat(chat): selective-keep options for Clear Chat"
```

---

### Task 2: `LocalConversationStore.resetKeeping`

**Files:**
- Modify: `aiGirlfriend/Services/LocalConversationStore.swift`

**Interfaces:**
- Consumes: existing `Stored` struct/`mem`/`lock`/`userKey()`.
- Produces: `func resetKeeping(for id: UUID, keepLevel: Bool)` — consumed by Task 4.

- [ ] **Step 1: Add the method**

In `aiGirlfriend/Services/LocalConversationStore.swift`, add this method after `refreshDetectedLanguage` (the last method added in the previous plan), before the closing `}` of the class:

```swift

    /// "Sohbeti Temizle" yerel sıfırlama — mesajları/özeti/durumu HER ZAMAN
    /// sıfırlar (server ile birebir aynı alanlar — bkz. chat/index.ts clear
    /// branch); relationship_level/level_progress SADECE `keepLevel` false
    /// ise sıfırlanır. Memories/behaviors istemcide hiç tutulmuyor (sadece
    /// server tablosu) — bu yüzden bu fonksiyonun keepMemories/keepBehaviors
    /// parametresi yok, o iki bayrak sadece ChatService çağrısını etkiler.
    /// Kayıt bu karakter için hiç yoksa hiçbir şey yapmaz.
    func resetKeeping(for id: UUID, keepLevel: Bool) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        guard mem[key]?[id] != nil else { return }
        mem[key]?[id]?.messages = []
        mem[key]?[id]?.summary = ""
        mem[key]?[id]?.summarizedCount = 0
        mem[key]?[id]?.schedule = nil
        mem[key]?[id]?.wokenUpAt = nil
        mem[key]?[id]?.manualSleepAt = nil
        mem[key]?[id]?.ghostedAt = nil
        mem[key]?[id]?.detectedLanguage = nil
        if !keepLevel {
            mem[key]?[id]?.level = 1
            mem[key]?[id]?.levelProgress = 0
        }
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/LocalConversationStore.swift
git commit -m "feat(client): add resetKeeping to LocalConversationStore for selective Clear Chat"
```

---

### Task 3: `ChatService` — thread the three flags through to the wire

**Files:**
- Modify: `aiGirlfriend/Services/ChatService.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `func clearConversation(character: Character, keepLevel: Bool = false, keepMemories: Bool = false, keepBehaviors: Bool = false) async throws` — consumed by Task 4.

- [ ] **Step 1: Add the three fields to `ChatRequest`**

Find (the last field in the struct):

```swift
    /// true ise az önce üretilen fotoğraf reddedilip yumuşatılmış bir
    /// versiyonla değiştirildi (bkz. chat-image/index.ts redirected alanı) —
    /// Grok normal foto tepkisi yerine "bunu şimdi yapamam ama bunu
    /// gönderebilirim" tarzı doğal bir yönlendirme cevabı yazmalı (bkz.
    /// chat/index.ts IMAGE_REDIRECT_RULE).
    let imageRedirected: Bool?
}
```

Replace with:

```swift
    /// true ise az önce üretilen fotoğraf reddedilip yumuşatılmış bir
    /// versiyonla değiştirildi (bkz. chat-image/index.ts redirected alanı) —
    /// Grok normal foto tepkisi yerine "bunu şimdi yapamam ama bunu
    /// gönderebilirim" tarzı doğal bir yönlendirme cevabı yazmalı (bkz.
    /// chat/index.ts IMAGE_REDIRECT_RULE).
    let imageRedirected: Bool?
    /// "Clear Chat" seçenekleri — sadece `clearConversation: true` ile
    /// birlikte anlamlı. bkz. ClearChatOptionsSheet, chat/index.ts clear branch.
    let keepLevel: Bool?
    let keepMemories: Bool?
    let keepBehaviors: Bool?
}
```

- [ ] **Step 2: Add the flags to `RequestExtra.clear` and thread them through `perform`**

Find:

```swift
    private enum RequestExtra {
        case none
        case clear
        case localHistory([WireHistoryMessage], summary: String?)
        case summarize([WireHistoryMessage], existing: String)
        case photoDownloadReaction([WireHistoryMessage], summary: String?, photoURL: String)
    }
```

Replace with:

```swift
    private enum RequestExtra {
        case none
        case clear(keepLevel: Bool, keepMemories: Bool, keepBehaviors: Bool)
        case localHistory([WireHistoryMessage], summary: String?)
        case summarize([WireHistoryMessage], existing: String)
        case photoDownloadReaction([WireHistoryMessage], summary: String?, photoURL: String)
    }
```

Find:

```swift
        var clearConversation: Bool? = nil
        var clientHistory: [WireHistoryMessage]? = nil
        var localSummary: String? = nil
        var summarizeMessages: [WireHistoryMessage]? = nil
        var existingSummary: String? = nil
        var photoDownloadReaction: Bool? = nil
        var photoURL: String? = nil

        switch extra {
        case .none:
            break
        case .clear:
            clearConversation = true
        case .localHistory(let h, let s):
```

Replace with:

```swift
        var clearConversation: Bool? = nil
        var keepLevel: Bool? = nil
        var keepMemories: Bool? = nil
        var keepBehaviors: Bool? = nil
        var clientHistory: [WireHistoryMessage]? = nil
        var localSummary: String? = nil
        var summarizeMessages: [WireHistoryMessage]? = nil
        var existingSummary: String? = nil
        var photoDownloadReaction: Bool? = nil
        var photoURL: String? = nil

        switch extra {
        case .none:
            break
        case .clear(let kl, let km, let kb):
            clearConversation = true
            keepLevel = kl
            keepMemories = km
            keepBehaviors = kb
        case .localHistory(let h, let s):
```

Find the `ChatRequest(...)` construction's closing lines:

```swift
            nearSleepTime: nearSleepTime,
            userImageBase64: userImageBase64,
            imageRedirected: imageRedirected
        )
```

Replace with:

```swift
            nearSleepTime: nearSleepTime,
            userImageBase64: userImageBase64,
            imageRedirected: imageRedirected,
            keepLevel: keepLevel,
            keepMemories: keepMemories,
            keepBehaviors: keepBehaviors
        )
```

- [ ] **Step 3: Update `clearConversation(character:)`'s signature**

Find:

```swift
    /// "Sohbeti Temizle" — sunucudaki conversation/messages satırlarını siler
    /// (cascade ile memories de gider). İstemci ayrıca kendi yerel kopyasını temizler.
    func clearConversation(character: Character) async throws {
        _ = try await perform(character: character, userMessage: nil, extra: .clear)
    }
```

Replace with:

```swift
    /// "Sohbeti Temizle" — varsayılan (üç bayrak da false) TÜM sunucu verisini
    /// sıfırlar; `keepLevel`/`keepMemories`/`keepBehaviors` true verilirse o
    /// veri korunur (bkz. chat/index.ts clear branch, ClearChatOptionsSheet).
    /// İstemci ayrıca kendi yerel kopyasını temizler (bkz. ChatMaintenance).
    func clearConversation(character: Character, keepLevel: Bool = false, keepMemories: Bool = false, keepBehaviors: Bool = false) async throws {
        _ = try await perform(character: character, userMessage: nil, extra: .clear(keepLevel: keepLevel, keepMemories: keepMemories, keepBehaviors: keepBehaviors))
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`. (`clearConversation`'s existing zero-argument callers still compile due to the new default parameter values.)

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/Services/ChatService.swift
git commit -m "feat(client): thread Clear Chat keep-options through ChatService"
```

---

### Task 4: `ChatMaintenance.clearChat` — wire the flags into local + server calls

**Files:**
- Modify: `aiGirlfriend/Services/ChatMaintenance.swift`

**Interfaces:**
- Consumes: `LocalConversationStore.shared.resetKeeping(for:keepLevel:)` (Task 2), `ChatService().clearConversation(character:keepLevel:keepMemories:keepBehaviors:)` (Task 3).
- Produces: `static func clearChat(character: Character, store: CharacterStore, keepLevel: Bool = false, keepMemories: Bool = false, keepBehaviors: Bool = false) async` — consumed by Task 5. `ChatListView`'s two existing call sites (`character:store:` only, no flags) keep compiling via the default `false` values.

- [ ] **Step 1: Make the change**

Find:

```swift
enum ChatMaintenance {
    /// Hem sunucudaki (conversation/messages) hem cihazdaki kaydı siler — aksi
    /// halde bir sonraki açılışta sunucudan eski geçmiş geri gelir (silinmiş gibi
    /// görünüp sonra "yeniden gönderilmiş" gibi geri dönerdi).
    @MainActor
    static func clearChat(character: Character, store: CharacterStore) async {
        store.chatCache[character.id] = []
        LocalConversationStore.shared.clear(for: character.id)
        ReadTracker.setSeen(character.id, 0)
        try? await ChatService().clearConversation(character: character)
    }

}
```

Replace with:

```swift
enum ChatMaintenance {
    /// Hem sunucudaki (conversation/messages) hem cihazdaki kaydı siler — aksi
    /// halde bir sonraki açılışta sunucudan eski geçmiş geri gelir (silinmiş gibi
    /// görünüp sonra "yeniden gönderilmiş" gibi geri dönerdi).
    /// `keepLevel`/`keepMemories`/`keepBehaviors`: varsayılan false — ChatListView'in
    /// uzun-basma menüsü bunları hiç geçmez (tam sıfırlama, bkz. ChatListView.swift),
    /// ChatView'in dişli menüsü ClearChatOptionsSheet üzerinden geçer.
    @MainActor
    static func clearChat(character: Character, store: CharacterStore, keepLevel: Bool = false, keepMemories: Bool = false, keepBehaviors: Bool = false) async {
        store.chatCache[character.id] = []
        if keepLevel {
            LocalConversationStore.shared.resetKeeping(for: character.id, keepLevel: true)
        } else {
            LocalConversationStore.shared.clear(for: character.id)
        }
        ReadTracker.setSeen(character.id, 0)
        try? await ChatService().clearConversation(character: character, keepLevel: keepLevel, keepMemories: keepMemories, keepBehaviors: keepBehaviors)
    }

}
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/ChatMaintenance.swift
git commit -m "feat(client): wire Clear Chat keep-options through ChatMaintenance"
```

---

### Task 5: `ChatViewModel.clearChat` — accept the flags

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `ChatMaintenance.clearChat(character:store:keepLevel:keepMemories:keepBehaviors:)` from Task 4.
- Produces: `func clearChat(keepLevel: Bool = false, keepMemories: Bool = false, keepBehaviors: Bool = false)` — consumed by Task 6.

- [ ] **Step 1: Make the change**

Find:

```swift
    func clearChat() {
        // Temizle = sohbet BOŞ kalır. Eskiden hemen ardından loadHistory()
        // çağrılıyordu; o da boş sohbette yeni conversation + "ilk selam"
        // oluşturup mesajı ANINDA geri getiriyordu (bkz. kullanıcı talebi:
        // "temizledim ama geri geliyor"). Artık yalnızca siler, boş bırakır —
        // ilk-selam yalnızca sohbet BİR SONRAKİ açılışında gelir.
        messages = []
        hasSyntheticOpening = false
        Task {
            if let store { await ChatMaintenance.clearChat(character: character, store: store) }
        }
    }
```

Replace with:

```swift
    func clearChat(keepLevel: Bool = false, keepMemories: Bool = false, keepBehaviors: Bool = false) {
        // Temizle = sohbet BOŞ kalır. Eskiden hemen ardından loadHistory()
        // çağrılıyordu; o da boş sohbette yeni conversation + "ilk selam"
        // oluşturup mesajı ANINDA geri getiriyordu (bkz. kullanıcı talebi:
        // "temizledim ama geri geliyor"). Artık yalnızca siler, boş bırakır —
        // ilk-selam yalnızca sohbet BİR SONRAKİ açılışında gelir.
        messages = []
        hasSyntheticOpening = false
        Task {
            if let store {
                await ChatMaintenance.clearChat(
                    character: character, store: store,
                    keepLevel: keepLevel, keepMemories: keepMemories, keepBehaviors: keepBehaviors
                )
            }
        }
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "feat(client): accept Clear Chat keep-options in ChatViewModel"
```

---

### Task 6: `ClearChatOptionsSheet` view + wire into `ChatView`

**Files:**
- Create: `aiGirlfriend/Views/ClearChatOptionsSheet.swift`
- Modify: `aiGirlfriend/Views/ChatView.swift`

**Interfaces:**
- Consumes: `viewModel.clearChat(keepLevel:keepMemories:keepBehaviors:)` from Task 5.
- Produces: `struct ClearChatOptionsSheet: View` with `init(character: Character, onConfirm: @escaping (_ keepLevel: Bool, _ keepMemories: Bool, _ keepBehaviors: Bool) -> Void)` — not consumed by any later task, this is the last task in the plan besides deploy/verify.

- [ ] **Step 1: Create the sheet**

Write `aiGirlfriend/Views/ClearChatOptionsSheet.swift`:

```swift
//
//  ClearChatOptionsSheet.swift
//  "Clear Chat" öncesi ne saklanacağını seçme ekranı — ChatView'in dişli
//  menüsünden açılır (bkz. ChatView.headerButton). Mesajlar/özet HER ZAMAN
//  silinir; burada sadece relationship_level/level_progress, memories ve
//  conversation_behaviors için "koru" seçilebilir (bkz. chat/index.ts clear
//  branch, ChatViewModel.clearChat).
//

import SwiftUI

struct ClearChatOptionsSheet: View {
    let character: Character
    let onConfirm: (_ keepLevel: Bool, _ keepMemories: Bool, _ keepBehaviors: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keepLevel = false
    @State private var keepMemories = false
    @State private var keepBehaviors = false
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppColor.bg.ignoresSafeArea()
                VStack(spacing: 16) {
                    Text("This clears your message history with \(character.name). Choose what to keep:")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 0) {
                        Toggle("Keep relationship level & progress", isOn: $keepLevel)
                            .padding(.vertical, 10)
                        Divider().overlay(.white.opacity(0.1))
                        Toggle("Keep memories", isOn: $keepMemories)
                            .padding(.vertical, 10)
                        Divider().overlay(.white.opacity(0.1))
                        Toggle("Keep behavior preferences", isOn: $keepBehaviors)
                            .padding(.vertical, 10)
                    }
                    .padding(.horizontal, 12)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .toggleStyle(SwitchToggleStyle(tint: AppColor.pink))
                    .foregroundStyle(.white)

                    Button(role: .destructive) {
                        onConfirm(keepLevel, keepMemories, keepBehaviors)
                        dismiss()
                    } label: {
                        Text("Clear Chat").font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 50)
                            .background(LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                                       startPoint: .leading, endPoint: .trailing), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { contentHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in contentHeight = h }
                    }
                )
            }
            .navigationTitle("Clear Chat")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(contentHeight + 56)])
        .presentationDragIndicator(.visible)
    }
}
```

- [ ] **Step 2: Wire it into `ChatView`**

Find:

```swift
    @State private var showProfile = false
    @State private var showTokenStore = false
    @State private var addSheetKind: NoteKind?
    @State private var showBlockConfirm = false
```

Replace with:

```swift
    @State private var showProfile = false
    @State private var showTokenStore = false
    @State private var addSheetKind: NoteKind?
    @State private var showBlockConfirm = false
    @State private var showClearChatOptions = false
```

Find:

```swift
                Button(role: .destructive) { viewModel.clearChat() } label: { Label("Clear Chat", systemImage: "trash") }
```

Replace with:

```swift
                Button(role: .destructive) { showClearChatOptions = true } label: { Label("Clear Chat", systemImage: "trash") }
```

Find the existing `.sheet(item: $addSheetKind) { kind in` modifier block's closing — locate it with:

Run: `grep -n "\.sheet(item: \$addSheetKind)" -A 5 aiGirlfriend/Views/ChatView.swift`

Add a new `.sheet(isPresented: $showClearChatOptions)` modifier immediately after that `.sheet(item: $addSheetKind) { ... }` block closes (same indentation level as the other view modifiers chained on the root view):

```swift
        .sheet(isPresented: $showClearChatOptions) {
            ClearChatOptionsSheet(character: viewModel.character) { keepLevel, keepMemories, keepBehaviors in
                viewModel.clearChat(keepLevel: keepLevel, keepMemories: keepMemories, keepBehaviors: keepBehaviors)
            }
        }
```

- [ ] **Step 3: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Views/ClearChatOptionsSheet.swift aiGirlfriend/Views/ChatView.swift
git commit -m "feat(client): add Clear Chat selective-keep dialog to ChatView"
```

---

### Task 7: Deploy and manually verify

**Files:** none (deploy + manual test only)

**Interfaces:**
- Consumes: the finished code from Tasks 1-6.
- Produces: nothing — final task.

- [ ] **Step 1: Deploy the backend change**

```bash
npx supabase functions deploy chat --project-ref ohpvhgwjmrfjclnumgnm
```

Expected: `"message":"Deployed Functions."`.

- [ ] **Step 2: Confirm the new version is live**

```bash
npx supabase functions list --project-ref ohpvhgwjmrfjclnumgnm
```

Confirm `chat`'s `version` incremented and `updated_at` is recent.

- [ ] **Step 3: Manual smoke test — full wipe (all boxes unchecked)**

In the app, open a chat with some history/level progress, tap the gear menu → Clear Chat, leave all three toggles off, confirm. Verify: messages gone, level reset to 1 on next message, bot doesn't reference old memories.

- [ ] **Step 4: Manual smoke test — keep level**

Build up some relationship level/progress in a chat, clear with "Keep relationship level & progress" ON, others off. Verify: messages gone, but level/progress on the next message matches what it was before clearing (not reset to 1).

- [ ] **Step 5: Manual smoke test — keep memories**

Have a conversation that generates a memory (e.g. tell the bot your name), clear with "Keep memories" ON. Verify: on the next message, the bot still references the memory (visible via its behavior, or by checking the `memories` table for that conversation in the Supabase dashboard — row should still exist).

- [ ] **Step 6: Manual smoke test — keep behaviors**

Add a behavior note via "Add Behavior", clear with "Keep behavior preferences" ON. Verify the `conversation_behaviors` row survives (dashboard check) and still gets injected (bot behavior reflects it on the next message).

- [ ] **Step 7: Manual smoke test — ChatListView long-press unaffected**

From the chat list, long-press a conversation and use its "Clear Chat" (not through `ChatView`). Verify: no dialog appears, full wipe happens exactly as before this plan (level resets, memories/behaviors gone).

- [ ] **Step 8: Report result**

No further commits needed — this task is verification only. If any smoke test in Steps 3-7 fails, stop and fix the relevant Task (1-6) before considering this plan complete.

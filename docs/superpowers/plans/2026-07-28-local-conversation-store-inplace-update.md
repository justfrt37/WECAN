# LocalConversationStore In-Place Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `ChatViewModel.updateCache()` — which rebuilds a full `Stored` value (including a fresh `Array(messages.dropFirst())` copy) on every message event — with targeted in-place mutations on `LocalConversationStore`, per `docs/superpowers/specs/2026-07-27-local-conversation-store-inplace-update-design.md`.

**Architecture:** Four new in-place methods on `LocalConversationStore` (`appendMessage`, `updateMessage`, `updateFields`, `refreshDetectedLanguage`), each mutating only the dictionary-value fields that actually changed instead of reconstructing the whole `Stored` struct. `ChatViewModel`'s 9 `updateCache()` call sites are each replaced with the specific mutation that call site needs. `updateCache()` itself is deleted once nothing calls it.

**Tech Stack:** Swift/SwiftUI. No test target exists (same constraint as the ImageCache plan) — verification is `xcodebuild build` plus manual smoke testing.

## Global Constraints

- Scope: `aiGirlfriend/Services/LocalConversationStore.swift` and `aiGirlfriend/ViewModels/ChatViewModel.swift` only.
- **Behavior must be exactly preserved**, including a subtlety in the current code: `updateCache()` recomputes `detectedLanguage` via `ConversationLanguage.resolve(latestAssistantText:previouslyDetected:)` on every call, using the latest assistant message's content. This only actually changes when a NEW assistant message was just appended (user-only appends leave "latest assistant text" unchanged, so recomputing there is a no-op today) — the new code must recompute it at exactly the same set of moments, not more, not fewer. In particular: `reactToPrivateDownload()` does **not** call `applyPostReplyEffects()` — it currently gets its `detectedLanguage` refresh entirely from its own direct `updateCache()` call, so it needs its own explicit `refreshDetectedLanguage` call in the new code, not a shared one bundled into `applyPostReplyEffects`.
- `Stored` (in `LocalConversationStore.swift`) stays a struct (spec explicitly decided against converting to a class) — all new methods mutate it via dictionary-subscript in-place assignment (`mem[key]?[id]?.field = ...`), never by reading out a full copy and writing the whole thing back.
- Out of scope (per spec): capping in-memory history length, evicting old messages from `mem` across a session. Not touched here.
- `store?.chatCache[character.id] = realMessages()` (the `CharacterStore` display-cache mirror, separate from `LocalConversationStore`) keeps being recomputed the same way it is today — this plan only removes the *separate, additional* full-`Stored`-rebuild that `updateCache()` used to do on top of that; it does not change `realMessages()`'s own cost, which the spec explicitly scoped out as a future, riskier pass.

---

### Task 1: Add in-place mutation API to `LocalConversationStore`

**Files:**
- Modify: `aiGirlfriend/Services/LocalConversationStore.swift`

**Interfaces:**
- Consumes: existing `Stored` struct, existing `mem`/`lock`/`userKey()` internals (all `private`, so these are new methods on the same type, not external consumers).
- Produces (consumed by Tasks 2-7):
  - `func appendMessage(_ message: Message, for id: UUID, defaultLevel: Int, defaultLevelProgress: Double)`
  - `func updateMessage(id: UUID, for characterId: UUID, mutate: (inout Message) -> Void)`
  - `func updateFields(for id: UUID, level: Int, levelProgress: Double, msgCounter: Int)`
  - `func refreshDetectedLanguage(for id: UUID)`

- [ ] **Step 1: Add the methods**

In `aiGirlfriend/Services/LocalConversationStore.swift`, add these methods to the `LocalConversationStore` class, after the existing `updateSummary(for:summary:summarizedCount:schedule:)` method and before the closing `}` of the class:

```swift

    // MARK: - Yerinde güncelleme (tam Stored yeniden inşa etmeden)

    /// Var olan bir kayda TEK bir mesaj ekler — mevcut dizinin sonuna in-place
    /// append yapar, `Stored`'un TÜMÜNÜ yeniden inşa etmez. Kayıt bu karakter
    /// için henüz yoksa (ör. senkron ilk-selamdan sonraki ilk gerçek mesaj —
    /// bkz. ChatViewModel.attachFirstHello, synthetic:true dalı hiç save()
    /// çağırmıyor) `defaultLevel`/`defaultLevelProgress` ile SIFIRDAN bir
    /// kayıt oluşturur — eski `updateCache()`'in "stored yoksa da çalış"
    /// davranışıyla birebir.
    func appendMessage(_ message: Message, for id: UUID, defaultLevel: Int, defaultLevelProgress: Double) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        if mem[key]?[id] != nil {
            mem[key]?[id]?.messages.append(message)
        } else {
            mem[key, default: [:]][id] = Stored(
                messages: [message], xp: 0, level: defaultLevel, summary: "",
                summarizedCount: 0, levelProgress: defaultLevelProgress
            )
        }
    }

    /// Var olan bir mesajı id'sinden bulup yerinde günceller (ör. bekleyen
    /// bir foto/ses balonunun üretim sonucu gelince doldurulması) — tüm
    /// mesaj dizisini kopyalamadan tek elemanı mutate eder. Kayıt ya da
    /// mesaj bulunamazsa sessizce hiçbir şey yapmaz.
    func updateMessage(id: UUID, for characterId: UUID, mutate: (inout Message) -> Void) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        guard let idx = mem[key]?[characterId]?.messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&mem[key]![characterId]!.messages[idx])
    }

    /// Seviye/ilerleme/mesaj-sayacı alanlarını yerinde günceller — mesaj
    /// dizisine dokunmaz. Kayıt yoksa hiçbir şey yapmaz (bu üç alan sadece
    /// `applyPostReplyEffects`'ten, yani bir mesaj zaten eklenmiş bir turun
    /// sonunda çağrılır — kayıt bu noktada zaten var olmalı).
    func updateFields(for id: UUID, level: Int, levelProgress: Double, msgCounter: Int) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        guard mem[key]?[id] != nil else { return }
        mem[key]?[id]?.level = level
        mem[key]?[id]?.levelProgress = levelProgress
        mem[key]?[id]?.msgCounter = msgCounter
    }

    /// `detectedLanguage`'ı en son asistan mesajından yeniden hesaplar
    /// (bkz. ConversationLanguage.resolve) — SADECE yeni bir asistan mesajı
    /// eklendiği anlarda çağrılmalı (bkz. ChatViewModel call site'ları).
    /// Kayıt ya da asistan mesajı yoksa hiçbir şey yapmaz.
    func refreshDetectedLanguage(for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        guard let latest = mem[key]?[id]?.messages.last(where: { $0.role == .assistant })?.content else { return }
        let previous = mem[key]?[id]?.detectedLanguage
        mem[key]?[id]?.detectedLanguage = ConversationLanguage.resolve(latestAssistantText: latest, previouslyDetected: previous)
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`. (These methods aren't called yet, so this just confirms the new code itself is syntactically/type valid — `Stored`'s memberwise init defaults for `msgCounter`/`detectedLanguage`/etc. are used, matching the struct's existing `init` defaults.)

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/LocalConversationStore.swift
git commit -m "perf(client): add in-place mutation API to LocalConversationStore"
```

---

### Task 2: Convert the simple single-append call sites (`send`, `sendUserVoice`, `sendUserPhoto`, `sendVoiceRequest`, first half of `sendImageRequest`)

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `LocalConversationStore.shared.appendMessage(_:for:defaultLevel:defaultLevelProgress:)` from Task 1.
- Produces: nothing new for later tasks.

- [ ] **Step 1: `send()`**

Find:

```swift
        // Zaman farkındalığı için — yeni mesajı eklemeden ÖNCEki son mesajın zamanı.
        let lastMessageAt = messages.last?.createdAt
        messages.append(Message(role: .user, content: text))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
```

Replace with:

```swift
        // Zaman farkındalığı için — yeni mesajı eklemeden ÖNCEki son mesajın zamanı.
        let lastMessageAt = messages.last?.createdAt
        let userMsg = Message(role: .user, content: text)
        messages.append(userMsg)
        LocalConversationStore.shared.appendMessage(userMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        store?.chatCache[character.id] = realMessages()
        NotificationScheduler.shared.noteUserSent(character: character)
```

- [ ] **Step 2: `sendUserVoice()`**

Find:

```swift
        messages.append(Message(
            id: messageID, role: .user, content: trimmed,
            voiceLocalPath: savedPath, voiceDuration: duration
        ))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
```

Replace with:

```swift
        let userMsg = Message(
            id: messageID, role: .user, content: trimmed,
            voiceLocalPath: savedPath, voiceDuration: duration
        )
        messages.append(userMsg)
        LocalConversationStore.shared.appendMessage(userMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        store?.chatCache[character.id] = realMessages()
        NotificationScheduler.shared.noteUserSent(character: character)
```

- [ ] **Step 3: `sendUserPhoto()`**

Find:

```swift
        messages.append(Message(id: messageID, role: .user, content: caption, localImagePath: savedPath))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
```

Replace with:

```swift
        let userMsg = Message(id: messageID, role: .user, content: caption, localImagePath: savedPath)
        messages.append(userMsg)
        LocalConversationStore.shared.appendMessage(userMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        store?.chatCache[character.id] = realMessages()
        NotificationScheduler.shared.noteUserSent(character: character)
```

- [ ] **Step 4: `sendVoiceRequest()`**

Find:

```swift
        let pendingID = UUID()
        messages.append(Message(role: .user, content: text))
        messages.append(Message(id: pendingID, role: .assistant, content: "", pendingVoiceRequest: true))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
```

Replace with:

```swift
        let pendingID = UUID()
        let userMsg = Message(role: .user, content: text)
        let pendingMsg = Message(id: pendingID, role: .assistant, content: "", pendingVoiceRequest: true)
        messages.append(userMsg)
        messages.append(pendingMsg)
        LocalConversationStore.shared.appendMessage(userMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        LocalConversationStore.shared.appendMessage(pendingMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        store?.chatCache[character.id] = realMessages()
        NotificationScheduler.shared.noteUserSent(character: character)
```

(`pendingMsg` has `content: ""` and no `pendingVoiceRequest` effect on detected language — this is a user-turn append, not an assistant reply, so no `refreshDetectedLanguage` call here, matching the constraint in Global Constraints.)

- [ ] **Step 5: `sendImageRequest()` — first append (user's photo-request text)**

Find:

```swift
        messages.append(Message(role: .user, content: text))
        updateCache()
        NotificationScheduler.shared.noteUserSent(character: character)
        inputText = ""
        isImageArmed = false
        errorMessage = nil
```

Replace with:

```swift
        let userMsg = Message(role: .user, content: text)
        messages.append(userMsg)
        LocalConversationStore.shared.appendMessage(userMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        store?.chatCache[character.id] = realMessages()
        NotificationScheduler.shared.noteUserSent(character: character)
        inputText = ""
        isImageArmed = false
        errorMessage = nil
```

- [ ] **Step 6: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`. (`updateCache()` still exists and is still called elsewhere, so no "unused function" issue yet.)

- [ ] **Step 7: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "perf(client): use in-place appendMessage for simple user-message sends"
```

---

### Task 3: Convert `deliverSegments()`

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `LocalConversationStore.shared.appendMessage(...)` from Task 1.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Make the change**

Find:

```swift
    private func deliverSegments(_ result: ChatReply, bubbleStartedAt: Date) async {
        let segments: [ReplySegment] = (result.replySegments?.isEmpty == false)
            ? result.replySegments!
            : [ReplySegment(text: result.reply, delaySeconds: 0)]

        for (index, segment) in segments.enumerated() {
            if index == 0 {
                // İlk parça: mevcut davranış — balon zaten çağrı ÖNCESİNDE
                // açılmıştı, sadece "bunu yazmak ne kadar sürerdi" kadar tamamla.
                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: segment.text.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            } else {
                // Sonraki parçalar: balonu YENİDEN aç, dramatik duraklamayı
                // "yazıyor..." animasyonuyla göster.
                showsTypingBubble = true
                store?.setTyping(character.id, true)
                try? await Task.sleep(nanoseconds: UInt64(segment.delaySeconds * 1_000_000_000))
            }
            showsTypingBubble = false
            store?.setTyping(character.id, false)
            messages.append(Message(role: .assistant, content: segment.text))
        }
    }
```

Replace with:

```swift
    private func deliverSegments(_ result: ChatReply, bubbleStartedAt: Date) async {
        let segments: [ReplySegment] = (result.replySegments?.isEmpty == false)
            ? result.replySegments!
            : [ReplySegment(text: result.reply, delaySeconds: 0)]

        for (index, segment) in segments.enumerated() {
            if index == 0 {
                // İlk parça: mevcut davranış — balon zaten çağrı ÖNCESİNDE
                // açılmıştı, sadece "bunu yazmak ne kadar sürerdi" kadar tamamla.
                let elapsed = Date().timeIntervalSince(bubbleStartedAt)
                let wanted = TypingTiming.duration(forReplyLength: segment.text.count)
                let remaining = wanted - elapsed
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            } else {
                // Sonraki parçalar: balonu YENİDEN aç, dramatik duraklamayı
                // "yazıyor..." animasyonuyla göster.
                showsTypingBubble = true
                store?.setTyping(character.id, true)
                try? await Task.sleep(nanoseconds: UInt64(segment.delaySeconds * 1_000_000_000))
            }
            showsTypingBubble = false
            store?.setTyping(character.id, false)
            let replyMsg = Message(role: .assistant, content: segment.text)
            messages.append(replyMsg)
            LocalConversationStore.shared.appendMessage(replyMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
        }
        LocalConversationStore.shared.refreshDetectedLanguage(for: character.id)
        store?.chatCache[character.id] = realMessages()
    }
```

(One `refreshDetectedLanguage`/`chatCache` sync after the whole loop, not per-segment — matches the "sweep once, not per-write" principle and is behaviorally equivalent since only the FINAL latest-assistant-text matters to `ConversationLanguage.resolve`.)

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "perf(client): use in-place appendMessage in deliverSegments"
```

---

### Task 4: Convert `sendImageRequest()`'s second append + `generatePendingImage()`

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `appendMessage`, `updateMessage`, `refreshDetectedLanguage` from Task 1.
- Produces: nothing new for later tasks.

- [ ] **Step 1: `sendImageRequest()`'s pending-bubble append**

Find:

```swift
        Task {
            let delay = Double.random(in: 0.5...1.0)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                messages.append(Message(role: .assistant, content: "", pendingImagePrompt: text))
            }
            updateCache()
        }
```

Replace with:

```swift
        Task {
            let delay = Double.random(in: 0.5...1.0)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let pendingMsg = Message(role: .assistant, content: "", pendingImagePrompt: text)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                messages.append(pendingMsg)
            }
            LocalConversationStore.shared.appendMessage(pendingMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
            store?.chatCache[character.id] = realMessages()
        }
```

(A `pendingImagePrompt` placeholder has empty `content`, so it doesn't affect `ConversationLanguage.resolve` — no `refreshDetectedLanguage` call needed here; the real text arrives later via the caption append in Step 3 below.)

- [ ] **Step 2: `generatePendingImage()`'s imageURL edit**

Find:

```swift
                if let finalIdx = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[finalIdx].imageURL = imageResult.url
                    messages[finalIdx].pendingImagePrompt = nil
                }
                generatingImageMessageIDs.remove(messageID)
                handleTokenBalance(imageResult.tokenBalance)
                updateCache()
```

Replace with:

```swift
                if let finalIdx = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[finalIdx].imageURL = imageResult.url
                    messages[finalIdx].pendingImagePrompt = nil
                }
                LocalConversationStore.shared.updateMessage(id: messageID, for: character.id) { msg in
                    msg.imageURL = imageResult.url
                    msg.pendingImagePrompt = nil
                }
                store?.chatCache[character.id] = realMessages()
                generatingImageMessageIDs.remove(messageID)
                handleTokenBalance(imageResult.tokenBalance)
```

- [ ] **Step 3: `generatePendingImage()`'s caption append**

Find:

```swift
                let caption = result.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if !caption.isEmpty {
                    messages.append(Message(role: .assistant, content: caption))
                }

                applyPostReplyEffects(gotPhoto: imageResult.url, stored: stored)
```

Replace with:

```swift
                let caption = result.reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if !caption.isEmpty {
                    let captionMsg = Message(role: .assistant, content: caption)
                    messages.append(captionMsg)
                    LocalConversationStore.shared.appendMessage(captionMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
                    LocalConversationStore.shared.refreshDetectedLanguage(for: character.id)
                    store?.chatCache[character.id] = realMessages()
                }

                applyPostReplyEffects(gotPhoto: imageResult.url, stored: stored)
```

- [ ] **Step 4: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "perf(client): use in-place mutation API in sendImageRequest/generatePendingImage"
```

---

### Task 5: Convert `generatePendingVoice()`

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `updateMessage`, `refreshDetectedLanguage` from Task 1.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Make the change**

Find:

```swift
                if let finalIdx = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[finalIdx].content = cleanedReply
                    messages[finalIdx].voiceLocalPath = savedPath
                    messages[finalIdx].voiceDuration = duration
                    messages[finalIdx].pendingVoiceRequest = nil
                }
                generatingVoiceMessageIDs.remove(messageID)

                applyPostReplyEffects(gotPhoto: nil, stored: stored)
```

Replace with:

```swift
                if let finalIdx = messages.firstIndex(where: { $0.id == messageID }) {
                    messages[finalIdx].content = cleanedReply
                    messages[finalIdx].voiceLocalPath = savedPath
                    messages[finalIdx].voiceDuration = duration
                    messages[finalIdx].pendingVoiceRequest = nil
                }
                LocalConversationStore.shared.updateMessage(id: messageID, for: character.id) { msg in
                    msg.content = cleanedReply
                    msg.voiceLocalPath = savedPath
                    msg.voiceDuration = duration
                    msg.pendingVoiceRequest = nil
                }
                LocalConversationStore.shared.refreshDetectedLanguage(for: character.id)
                store?.chatCache[character.id] = realMessages()
                generatingVoiceMessageIDs.remove(messageID)

                applyPostReplyEffects(gotPhoto: nil, stored: stored)
```

(This message's `content` starts as `""` from `sendVoiceRequest`'s placeholder and only becomes real text here, when the voice reply is actually generated — that's the moment its content first affects `ConversationLanguage.resolve`, so the `refreshDetectedLanguage` call belongs here, not at the placeholder-append site in Task 2 Step 4.)

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "perf(client): use in-place updateMessage in generatePendingVoice"
```

---

### Task 6: Convert `reactToPrivateDownload()`

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `appendMessage`, `refreshDetectedLanguage` from Task 1.
- Produces: nothing new for later tasks.

- [ ] **Step 1: Make the change**

Find:

```swift
            messages.append(Message(role: .assistant, content: trimmed))
            updateCache()
            store?.conversationsVersion += 1
```

Replace with:

```swift
            let replyMsg = Message(role: .assistant, content: trimmed)
            messages.append(replyMsg)
            LocalConversationStore.shared.appendMessage(replyMsg, for: character.id, defaultLevel: relationshipLevel, defaultLevelProgress: levelProgress)
            LocalConversationStore.shared.refreshDetectedLanguage(for: character.id)
            store?.chatCache[character.id] = realMessages()
            store?.conversationsVersion += 1
```

This is the site called out in Global Constraints — `reactToPrivateDownload()` never calls `applyPostReplyEffects()`, so it needs its own explicit `refreshDetectedLanguage` call here to match the original `updateCache()`-on-every-call behavior.

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "perf(client): use in-place appendMessage in reactToPrivateDownload"
```

---

### Task 7: Convert `applyPostReplyEffects()` and delete `updateCache()`

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `updateFields` from Task 1.
- Produces: nothing — this is the last call site, and removes the now-dead `updateCache()`/`realMessages()`-adjacent private method.

- [ ] **Step 1: Replace the `updateCache(msgCounter:)` call**

Find:

```swift
        updateCache(msgCounter: counter)
        if isVisible { markReadNow() }

        triggerSummarizationIfNeeded()
    }
```

Replace with:

```swift
        LocalConversationStore.shared.updateFields(
            for: character.id, level: relationshipLevel, levelProgress: levelProgress, msgCounter: counter
        )
        if isVisible { markReadNow() }

        triggerSummarizationIfNeeded()
    }
```

(No `chatCache` resync needed here — every call path into `applyPostReplyEffects` [`send`→`deliverSegments`, `sendUserVoice`→`deliverSegments`, `sendUserPhoto`→`deliverSegments`, `generatePendingVoice`] already synced `store?.chatCache[character.id]` at its own message-append/edit site in Tasks 2-5, before `applyPostReplyEffects` runs.)

- [ ] **Step 2: Delete the now-unused `updateCache` method**

Find and delete entirely:

```swift
    private func updateCache(msgCounter: Int? = nil) {
        let real = realMessages()
        guard !real.isEmpty else { return }
        store?.chatCache[character.id] = real
        let stored = LocalConversationStore.shared.load(for: character.id)
        let updated = LocalConversationStore.Stored(
            messages: real,
            xp: stored?.xp ?? 0,
            level: relationshipLevel,
            summary: stored?.summary ?? "",
            summarizedCount: stored?.summarizedCount ?? 0,
            msgCounter: msgCounter ?? stored?.msgCounter ?? 0,
            levelProgress: levelProgress,
            detectedLanguage: ConversationLanguage.resolve(
                latestAssistantText: real.last(where: { $0.role == .assistant })?.content,
                previouslyDetected: stored?.detectedLanguage
            ),
            schedule: stored?.schedule,
            wokenUpAt: stored?.wokenUpAt,
            manualSleepAt: stored?.manualSleepAt
        )
        LocalConversationStore.shared.save(updated, for: character.id)
    }
```

- [ ] **Step 3: Verify nothing else calls it**

Run: `grep -n "updateCache(" aiGirlfriend/ViewModels/ChatViewModel.swift`
Expected: no output (zero matches) — every call site was converted in Tasks 2-6.

- [ ] **Step 4: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **` — this also confirms `updateCache` had no other silent callers (an unremoved call site would fail to compile with "cannot find 'updateCache' in scope").

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "perf(client): use in-place updateFields in applyPostReplyEffects, remove dead updateCache"
```

---

### Task 8: Manual verification

**Files:** none

**Interfaces:**
- Consumes: the finished code from Tasks 1-7.
- Produces: nothing — final task.

- [ ] **Step 1: Smoke test every converted flow**

Run the app in the simulator. For each of these, confirm behavior is unchanged from before this plan:
- Send a plain text message (`send`) — appears immediately (optimistic UI), reply arrives, level/XP ring updates correctly.
- Send a message with `[PAUSE:n]`-style multi-bubble reply if you can trigger one (`deliverSegments`) — all bubbles appear correctly.
- Record and send a voice message (`sendUserVoice`).
- Send a photo to the bot (`sendUserPhoto`).
- Request a voice reply, then tap to generate it (`sendVoiceRequest` + `generatePendingVoice`).
- Request a photo reply, then tap to generate it (`sendImageRequest` + `generatePendingImage`) — confirm both the image AND its caption reaction appear.
- Download a private/intimate photo for the first time (`reactToPrivateDownload`) — confirm the reaction line appears.

- [ ] **Step 2: Confirm persistence survives backgrounding**

After a few of the above, background and reforeground the app (or navigate away from the chat and back). Confirm the conversation history, relationship level, and level progress are all still correct — this is the core regression risk of this plan (in-place mutations writing to the wrong place, or a message silently not persisting).

- [ ] **Step 3: Confirm detected-language tracking still works**

Have a conversation in a non-English/non-Turkish supported language (e.g. German or Spanish) long enough to trigger a proactive notification content lookup (or check `ConversationLanguage.current(for:)`-driven behavior some other way available in the app) — confirm the detected language still updates correctly, since this is the subtlest behavior this plan had to preserve.

- [ ] **Step 4: Report result**

No further commits needed — this task is verification only. If any smoke test in Steps 1-3 shows a regression (missing messages, wrong level, stale detected language), stop and fix the relevant Task (1-7) before considering this plan complete.

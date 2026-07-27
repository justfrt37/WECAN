# Failed-Send Retry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-bubble failed state and tap-to-retry for `send`/`sendUserVoice`/`sendUserPhoto`, per `docs/superpowers/specs/2026-07-28-failed-send-retry-design.md`.

**Architecture:** `Message` gets a new optional `failed` flag. The three send flows' `catch` blocks set it on the specific message that failed (instead of only the generic `errorMessage` caption). A new `ChatViewModel.retrySend(messageID:)` removes the failed message (from both `messages` and `LocalConversationStore`) and re-invokes the matching original send function using the failed message's own content/attachment. `ChatBubble` gets a small red failed-indicator icon (only for the user's own failed messages) wired to call `retrySend`.

**Tech Stack:** Swift/SwiftUI. No test target (same constraint as prior client plans) — verification is `xcodebuild build` + manual smoke testing (force a network failure).

## Global Constraints

- Only `send`, `sendUserVoice`, `sendUserPhoto` get failed-state/retry — `sendImageRequest`/`sendVoiceRequest`/`generatePendingImage`/`generatePendingVoice` already have working implicit retry via their pending-state mechanism (their bubble stays `isPendingImage`/`isPendingVoice` and remains tappable on failure) and are NOT touched.
- The existing `isInsufficientTokensError(error)` branch in each catch block (which opens the paywall) is unaffected — failed-state only applies to the `else` branch (genuine send failures, not insufficient-token 402s).
- The generic `errorMessage` caption stays as-is for errors not tied to a specific message bubble (e.g. history load failures) — not removed.
- No automatic retry/backoff — manual tap-to-retry only.

---

### Task 1: Add `failed` to the `Message` model

**Files:**
- Modify: `aiGirlfriend/Models/Message.swift`

**Interfaces:**
- Produces: `Message.failed: Bool?` (defaults to `nil`, same optional-with-no-explicit-default pattern as `pendingVoiceRequest`) — consumed by Tasks 2, 3, 4, 5.

- [ ] **Step 1: Add the field**

In `aiGirlfriend/Models/Message.swift`, add the field and update `init`:

Find:

```swift
    /// true ve `voiceLocalPath` hâlâ nil'se: "ödeme bekleyen" bir sesli mesaj
    /// isteği (bkz. ChatViewModel.generatePendingVoice). Metin tarifi tutmaz —
    /// asıl bot cevabı da dokunulunca üretilir, o anki sohbet geçmişinden gelir.
    var pendingVoiceRequest: Bool?

    init(
        id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date(),
        imageURL: URL? = nil, voiceLocalPath: String? = nil, voiceDuration: Double? = nil,
        localImagePath: String? = nil, pendingImagePrompt: String? = nil, pendingVoiceRequest: Bool? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.imageURL = imageURL
        self.voiceLocalPath = voiceLocalPath
        self.voiceDuration = voiceDuration
        self.localImagePath = localImagePath
        self.pendingImagePrompt = pendingImagePrompt
        self.pendingVoiceRequest = pendingVoiceRequest
    }
```

Replace with:

```swift
    /// true ve `voiceLocalPath` hâlâ nil'se: "ödeme bekleyen" bir sesli mesaj
    /// isteği (bkz. ChatViewModel.generatePendingVoice). Metin tarifi tutmaz —
    /// asıl bot cevabı da dokunulunca üretilir, o anki sohbet geçmişinden gelir.
    var pendingVoiceRequest: Bool?
    /// true ise bu mesajın gönderimi başarısız oldu (ağ hatası vb., 402 hariç —
    /// bkz. ChatViewModel.isInsufficientTokensError) — balon üzerinde bir hata
    /// göstergesi gösterilir, dokununca yeniden denenir (bkz. ChatViewModel.retrySend).
    var failed: Bool?

    init(
        id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date(),
        imageURL: URL? = nil, voiceLocalPath: String? = nil, voiceDuration: Double? = nil,
        localImagePath: String? = nil, pendingImagePrompt: String? = nil, pendingVoiceRequest: Bool? = nil,
        failed: Bool? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.imageURL = imageURL
        self.voiceLocalPath = voiceLocalPath
        self.voiceDuration = voiceDuration
        self.localImagePath = localImagePath
        self.pendingImagePrompt = pendingImagePrompt
        self.pendingVoiceRequest = pendingVoiceRequest
        self.failed = failed
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`. (`failed` defaults to `nil`, so every existing `Message(...)` call site keeps compiling unchanged.)

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Models/Message.swift
git commit -m "feat(client): add failed flag to Message model"
```

---

### Task 2: `LocalConversationStore.removeMessage`

**Files:**
- Modify: `aiGirlfriend/Services/LocalConversationStore.swift`

**Interfaces:**
- Produces: `func removeMessage(id: UUID, for characterId: UUID)` — consumed by Task 4.

- [ ] **Step 1: Add the method**

In `aiGirlfriend/Services/LocalConversationStore.swift`, add this method after `resetKeeping` (the last method added in the previous plan), before the closing `}` of the class:

```swift

    /// Belirli bir mesajı kayıttan kaldırır — retrySend'in başarısız mesajı
    /// silip aynı içerikle yenisini eklemesi için (bkz. ChatViewModel.retrySend).
    /// Kayıt ya da mesaj bulunamazsa hiçbir şey yapmaz.
    func removeMessage(id: UUID, for characterId: UUID) {
        lock.lock(); defer { lock.unlock() }
        let key = userKey()
        mem[key]?[characterId]?.messages.removeAll(where: { $0.id == id })
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Services/LocalConversationStore.swift
git commit -m "feat(client): add removeMessage to LocalConversationStore"
```

---

### Task 3: Mark `failed` in the three catch blocks

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `Message.failed` from Task 1.
- Produces: nothing new for later tasks.

- [ ] **Step 1: `send()`**

Find:

```swift
            } catch {
                if isInsufficientTokensError(error) {
                    presentInsufficientTokensPaywall()   // uyarı yok, paywall aç
                } else {
                    errorMessage = error.localizedDescription
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// `send()`/`sendUserVoice()`/`sendUserPhoto()` ortak balon teslim mantığı —
```

Replace with:

```swift
            } catch {
                if isInsufficientTokensError(error) {
                    presentInsufficientTokensPaywall()   // uyarı yok, paywall aç
                } else {
                    errorMessage = error.localizedDescription
                    if let idx = messages.firstIndex(where: { $0.id == userMsg.id }) {
                        messages[idx].failed = true
                    }
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// `send()`/`sendUserVoice()`/`sendUserPhoto()` ortak balon teslim mantığı —
```

- [ ] **Step 2: `sendUserVoice()`**

Find:

```swift
            } catch {
                if isInsufficientTokensError(error) {
                    presentInsufficientTokensPaywall()   // uyarı yok, paywall aç
                } else {
                    errorMessage = error.localizedDescription
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// Kullanıcının BOTA gönderdiği kendi fotoğrafı (kamera/kütüphane) —
```

Replace with:

```swift
            } catch {
                if isInsufficientTokensError(error) {
                    presentInsufficientTokensPaywall()   // uyarı yok, paywall aç
                } else {
                    errorMessage = error.localizedDescription
                    if let idx = messages.firstIndex(where: { $0.id == userMsg.id }) {
                        messages[idx].failed = true
                    }
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// Kullanıcının BOTA gönderdiği kendi fotoğrafı (kamera/kütüphane) —
```

- [ ] **Step 3: `sendUserPhoto()`**

Find:

```swift
            } catch {
                if isInsufficientTokensError(error) {
                    presentInsufficientTokensPaywall()   // uyarı yok, paywall aç
                } else {
                    errorMessage = error.localizedDescription
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// Sesli mesaj isteği bayrağı — `quickReplyRow`'daki dalga formu düğmesiyle
```

Replace with:

```swift
            } catch {
                if isInsufficientTokensError(error) {
                    presentInsufficientTokensPaywall()   // uyarı yok, paywall aç
                } else {
                    errorMessage = error.localizedDescription
                    if let idx = messages.firstIndex(where: { $0.id == userMsg.id }) {
                        messages[idx].failed = true
                    }
                }
                showsTypingBubble = false
                store?.setTyping(character.id, false)
            }
            isSending = false
        }
    }

    /// Sesli mesaj isteği bayrağı — `quickReplyRow`'daki dalga formu düğmesiyle
```

(This edit relies on unique surrounding context — the comment line immediately after each catch block's closing brace differs between the three sites, which is why each `old_string` above is distinct even though the catch body itself is identical.)

- [ ] **Step 4: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "feat(client): mark message failed on send error"
```

---

### Task 4: `ChatViewModel.retrySend`

**Files:**
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift`

**Interfaces:**
- Consumes: `LocalConversationStore.shared.removeMessage(id:for:)` (Task 2), `Message.failed`/`voiceLocalPath`/`localImagePath` (Task 1), existing `send(_:)`, `sendUserVoice(transcript:audioURL:)`, `sendUserPhoto(image:caption:)`, `UserPhotoStore.loadUserPhoto(relativePath:)`, `VoicePlayer.voiceMessagesDirectory` (existing internal-access static, confirmed accessible from this file — same module).
- Produces: `func retrySend(messageID: UUID)` — consumed by Task 5.

- [ ] **Step 1: Add the method**

Add this method to `ChatViewModel`, right after `clearChat(keepLevel:keepMemories:keepBehaviors:)`:

```swift

    /// Başarısız bir mesaj balonuna dokununca — eski (failed) mesajı kaldırır,
    /// AYNI içerikle orijinal gönderim yolunu (send/sendUserVoice/sendUserPhoto)
    /// yeniden çağırır. Hangi yolun kullanılacağı mesajın kendi alanlarından
    /// çıkarılır: voiceLocalPath doluysa sesli mesaj, localImagePath doluysa
    /// kullanıcı fotoğrafı, ikisi de yoksa düz metin.
    func retrySend(messageID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }),
              messages[idx].failed == true
        else { return }
        let failedMsg = messages[idx]
        messages.remove(at: idx)
        LocalConversationStore.shared.removeMessage(id: messageID, for: character.id)
        store?.chatCache[character.id] = realMessages()

        if let voicePath = failedMsg.voiceLocalPath {
            let audioURL = VoicePlayer.voiceMessagesDirectory.appendingPathComponent(voicePath)
            sendUserVoice(transcript: failedMsg.content, audioURL: audioURL)
        } else if let photoPath = failedMsg.localImagePath,
                  let image = UserPhotoStore.loadUserPhoto(relativePath: photoPath) {
            sendUserPhoto(image: image, caption: failedMsg.content)
        } else {
            send(failedMsg.content)
        }
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "feat(client): add retrySend to ChatViewModel"
```

---

### Task 5: `ChatBubble` failed indicator + wire into `ChatView`

**Files:**
- Modify: `aiGirlfriend/Views/ChatView.swift`

**Interfaces:**
- Consumes: `Message.failed` (Task 1), `viewModel.retrySend(messageID:)` (Task 4).
- Produces: `ChatBubble.onRetry: (() -> Void)?` new parameter — not consumed elsewhere, this is the last code task.

- [ ] **Step 1: Add the `onRetry` parameter to `ChatBubble`**

Find:

```swift
private struct ChatBubble: View {
    let message: Message
    var isSpeaking: Bool = false
    var showsTimestamp: Bool = false
    var onTap: (() -> Void)? = nil
```

Replace with:

```swift
private struct ChatBubble: View {
    let message: Message
    var isSpeaking: Bool = false
    var showsTimestamp: Bool = false
    var onTap: (() -> Void)? = nil
    var onRetry: (() -> Void)? = nil
```

- [ ] **Step 2: Render the failed indicator**

Find:

```swift
            if showsTimestamp, message.isUser {
                timestampLabel
            }

            if message.isPendingImage {
```

Replace with:

```swift
            if showsTimestamp, message.isUser {
                timestampLabel
            }

            if message.isUser, message.failed == true {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.red)
                    .onTapGesture { onRetry?() }
            }

            if message.isPendingImage {
```

(Placed between the timestamp and the bubble content, matching the iMessage/WhatsApp convention of the failed-indicator sitting just outside the bubble on its leading side for outgoing messages.)

- [ ] **Step 3: Wire `onRetry` at the call site**

Run: `grep -n "ChatBubble(message: message," -A 5 aiGirlfriend/Views/ChatView.swift`

Find the `ChatBubble(...)` construction (starts with `ChatBubble(message: message,` followed by `isSpeaking:`, `showsTimestamp:`, `onTap:` closure). Add `onRetry:` right after the existing `onTap:` closure's closing `}, `:

Find:

```swift
                        ChatBubble(message: message,
                                   isSpeaking: voice.speakingMessageID == message.id,
                                   showsTimestamp: expandedMessageID == message.id,
                                   onTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedMessageID = expandedMessageID == message.id ? nil : message.id
                            }
                        }, onSpeak: {
```

Replace with:

```swift
                        ChatBubble(message: message,
                                   isSpeaking: voice.speakingMessageID == message.id,
                                   showsTimestamp: expandedMessageID == message.id,
                                   onTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                expandedMessageID = expandedMessageID == message.id ? nil : message.id
                            }
                        }, onRetry: {
                            viewModel.retrySend(messageID: message.id)
                        }, onSpeak: {
```

- [ ] **Step 4: Verify it compiles**

Run: `xcodebuild build -project /Users/furkanozsoy/Desktop/Projects/aigf/WECAN/aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/Views/ChatView.swift
git commit -m "feat(client): show failed indicator and wire tap-to-retry in ChatBubble"
```

---

### Task 6: Manual verification

**Files:** none

**Interfaces:**
- Consumes: the finished code from Tasks 1-5.
- Produces: nothing — final task.

- [ ] **Step 1: Force a plain-text send failure**

Turn on airplane mode (or otherwise break connectivity), send a plain text message. Confirm: the message bubble shows the red failed indicator, the generic error caption still appears below the list (unchanged behavior for the non-message-specific case). Turn connectivity back on, tap the failed bubble, confirm it resends and the failed indicator clears on success.

- [ ] **Step 2: Force a voice-message send failure**

Record and send a voice message with connectivity off. Confirm the failed indicator appears on that bubble. Restore connectivity, tap to retry, confirm the SAME audio re-sends successfully (not a re-recording prompt).

- [ ] **Step 3: Force a photo-send failure**

Send a photo to the bot with connectivity off. Confirm the failed indicator appears. Restore connectivity, tap to retry, confirm the SAME photo re-sends successfully.

- [ ] **Step 4: Confirm insufficient-tokens path is unaffected**

With a balance too low to send (or however this is testable — e.g. DEV token tools), attempt a send. Confirm the PRO/coin-store paywall opens as before, and the bubble does NOT show a failed indicator (that path uses `presentInsufficientTokensPaywall()`, not the `failed` flag).

- [ ] **Step 5: Report result**

No further commits needed — this task is verification only. If any smoke test in Steps 1-4 fails, stop and fix the relevant Task (1-5) before considering this plan complete.

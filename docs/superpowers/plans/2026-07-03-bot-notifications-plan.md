# Bot Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build 4 local-notification re-engagement systems (Liked You, Ghosted, Jealousy Bait, Level-Up Tease) plus a per-bot daily-cap settings menu, entirely on-device, per `docs/superpowers/specs/2026-07-03-bot-notifications-design.md`.

**Architecture:** A single `NotificationScheduler` singleton (mirrors the existing `LocalConversationStore`/`BlockedCharactersStore` singleton pattern) owns all scheduling. Static Swift dictionaries hold dialogue content keyed by role/vibe/tier. A `NotificationPreferencesStore` (UserDefaults, mirrors `BlockedCharactersStore`) holds per-bot daily caps + fired counts. Tap handling injects a message directly into `LocalConversationStore` and reuses the existing `MeetRequest`/`pendingMeetRequest` navigation pattern already wired in `MainTabView`.

**Tech Stack:** SwiftUI, `UNUserNotificationCenter` (local notifications only, no APNs), `UserDefaults`, existing `LocalConversationStore`/`CharacterStore`/`BlockedCharactersStore`.

## Global Constraints

- Local notifications only — no backend/edge-function/APNs changes (per spec).
- No push/remote infra: everything scheduled and resolved on-device.
- Blocked bots (`BlockedCharactersStore.isBlocked`) never get Ghosted/Jealousy/Level-Up notifications.
- Role intervals (Ghosted), the 2-10min Jealousy window, and the 80%/1-minute Level-Up rule are fixed constants — not user-editable.
- Daily cap UI shows `∞` (infinity symbol), never the word "Infinite".
- **No XCTest target exists in this project** (verified: no `*Tests.swift` files, no test target in `project.pbxproj`). Adding one is out of scope for this feature. Each task's verification step is therefore either (a) a full project build via `xcodebuild build`, or (b) for pure-logic pieces, a standalone `swift` script run via `swift path/to/script.swift` that imports nothing project-specific and asserts behavior inline — not XCTest, but a real executable check, per this project's existing no-test-infra convention (see `gotchas_and_fixes.md`).
- All new user-facing strings wrapped in `String(localized:)` per existing convention (`IcebreakerPool.swift`), matching the app's English-source `Localizable.xcstrings`. Turkish translations for the new content are explicitly deferred (follow-up work, same as other localization debt tracked in project memory) — not a blocker for this feature to function.
- Follow the existing raw-`String` role convention (`"flirty" | "distant" | "shy" | "playful" | "devoted" | "crazy" | "ex"`) — the codebase has no `PersonalityRole` enum (see `Relationship.swift`'s `switch role { case "distant": ... }`); do not introduce one for this feature, stay consistent.
- Vibe values are the 4 raw strings already used in `CreateCharacterView.swift`: `"Sweet" | "Mysterious" | "Energetic" | "Elegant"`.

---

### Task 1: Backfill `vibe` for the 15 seed catalog characters

The `vibe` axis (`Sweet`/`Mysterious`/`Energetic`/`Elegant`) is only ever set for user-created characters today (`CharacterCreateService.swift:25` sends it into `builder_selections`). The 15 seed characters in `supabase/seed_characters.sql` have `builder_selections = NULL`. Ghosted/Jealousy content selection needs every bot — system or user-created — to have a vibe.

**Files:**
- Create: `supabase/migrations/003_character_vibe_backfill.sql`
- Modify: `supabase/seed_characters.sql` (add `builder_selections` column + values so future re-runs stay consistent)

**Interfaces:**
- Produces: every row in `characters` has `builder_selections->>'vibe'` set to one of the 4 vibe strings (system rows via this migration, user-created rows already via existing `create-character` flow).

- [ ] **Step 1: Write the migration**

```sql
-- supabase/migrations/003_character_vibe_backfill.sql
-- Backfills builder_selections->>'vibe' for the 15 seed catalog characters.
-- Vibe picked to match each character's existing tagline/system_prompt tone.

update characters set builder_selections = jsonb_build_object('vibe', 'Sweet')
  where id = '00000000-0000-0000-0000-000000000101'; -- Sofia: warm, adoring photographer
update characters set builder_selections = jsonb_build_object('vibe', 'Elegant')
  where id = '00000000-0000-0000-0000-000000000102'; -- Emma: calm, caring yoga instructor
update characters set builder_selections = jsonb_build_object('vibe', 'Energetic')
  where id = '00000000-0000-0000-0000-000000000103'; -- Camila: energetic, passionate dancer
update characters set builder_selections = jsonb_build_object('vibe', 'Elegant')
  where id = '00000000-0000-0000-0000-000000000104'; -- Mia: elegant fashion designer
update characters set builder_selections = jsonb_build_object('vibe', 'Mysterious')
  where id = '00000000-0000-0000-0000-000000000105'; -- Hannah: driven, sharp architect

update characters set builder_selections = jsonb_build_object('vibe', 'Mysterious')
  where id = '00000000-0000-0000-0000-000000000201'; -- Seraphina: ageless sorceress
update characters set builder_selections = jsonb_build_object('vibe', 'Mysterious')
  where id = '00000000-0000-0000-0000-000000000202'; -- Lyra: celestial star mage
update characters set builder_selections = jsonb_build_object('vibe', 'Energetic')
  where id = '00000000-0000-0000-0000-000000000203'; -- Freya: fearless warrior princess
update characters set builder_selections = jsonb_build_object('vibe', 'Mysterious')
  where id = '00000000-0000-0000-0000-000000000204'; -- Morgana: teasing enchantress
update characters set builder_selections = jsonb_build_object('vibe', 'Energetic')
  where id = '00000000-0000-0000-0000-000000000205'; -- Aurora: brave dragon rider

update characters set builder_selections = jsonb_build_object('vibe', 'Sweet')
  where id = '00000000-0000-0000-0000-000000000301'; -- Yuki: shy, sweet student
update characters set builder_selections = jsonb_build_object('vibe', 'Energetic')
  where id = '00000000-0000-0000-0000-000000000302'; -- Sakura: cheerful pop idol
update characters set builder_selections = jsonb_build_object('vibe', 'Sweet')
  where id = '00000000-0000-0000-0000-000000000303'; -- Hina: bubbly café waitress
update characters set builder_selections = jsonb_build_object('vibe', 'Mysterious')
  where id = '00000000-0000-0000-0000-000000000304'; -- Rei: cool, focused mecha pilot
update characters set builder_selections = jsonb_build_object('vibe', 'Sweet')
  where id = '00000000-0000-0000-0000-000000000305'; -- Akari: kind-hearted magical girl
```

- [ ] **Step 2: Apply the migration**

Per `gotchas_and_fixes.md`: no local `psql`/Supabase CLI available on this machine — use the Supabase Management API DDL endpoint (same approach used for the `conversation_behaviors` migration). Use `$$-quoting$$` if needed to avoid apostrophe-escaping issues (none of these statements have apostrophes, so plain quoting is fine).

- [ ] **Step 3: Verify**

Run a `select id, name, builder_selections->>'vibe' as vibe from characters where builder_selections is not null order by id;` against the Management API REST endpoint (or `supabase/functions` service-role query) and confirm all 15 seed IDs return a non-null vibe matching the table above.

- [ ] **Step 4: Mirror into seed file for future re-runs**

Add `builder_selections` to the seed file's column list and each row's `values` tuple (same vibe values as Step 1), and add `builder_selections = excluded.builder_selections` to the `on conflict` clause, so re-running the seed script doesn't wipe the backfill.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/003_character_vibe_backfill.sql supabase/seed_characters.sql
git commit -m "feat: backfill vibe for seed catalog characters"
```

---

### Task 2: Expose `vibe` on the `Character` model

**Files:**
- Modify: `aiGirlfriend/Models/Character.swift`

**Interfaces:**
- Consumes: nothing new — reads `builder_selections` from the same REST payload `CharacterService.fetchAll()` already fetches (`select=*`).
- Produces: `Character.vibe: String` (non-optional, defaults to `"Sweet"` when absent), used by Tasks 4, 5, 7.

- [ ] **Step 1: Add the field and decode logic**

Open `aiGirlfriend/Models/Character.swift`. Add a stored property next to `personalityRole` (around line 30):

```swift
var personalityRole: String  // flirty | distant | shy | playful | devoted | crazy | ex
var vibe: String             // Sweet | Mysterious | Energetic | Elegant — from builder_selections.vibe
```

In the memberwise `init` (around line 67), add a parameter with a default:

```swift
personalityRole: String = "flirty",
vibe: String = "Sweet",
```

and assign it (`self.vibe = vibe`) next to `self.personalityRole = personalityRole` (line 86).

In `init(from decoder:)` (around line 91-109), `builder_selections` arrives as a nested JSON object, not a flat column — decode it defensively since it's `NULL` for characters not yet covered by Task 1 and absent from `CodingKeys` today:

```swift
private struct BuilderSelections: Decodable {
    let vibe: String?
}
```

Add `builderSelections` to the `CodingKeys` enum (`case builderSelections = "builder_selections"`), then in `init(from decoder:)` add, next to the `personalityRole` decode line:

```swift
let builderSelections = try? c.decodeIfPresent(BuilderSelections.self, forKey: .builderSelections)
vibe = builderSelections??.vibe ?? "Sweet"
```

(Double `??` because `decodeIfPresent` returns `BuilderSelections??` when combined with `try?` — collapses "key missing", "value is JSON null", and "vibe key missing inside the object" all to the `"Sweet"` fallback.)

- [ ] **Step 2: Verify it builds**

Run: `xcodebuild -project aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`, no decode-related warnings on `Character.swift`.

- [ ] **Step 3: Commit**

```bash
git add aiGirlfriend/Models/Character.swift
git commit -m "feat: decode character vibe from builder_selections"
```

---

### Task 3: Role-only content — Liked You (7 lines) + Level-Up Tease (7 lines)

**Files:**
- Create: `aiGirlfriend/Services/Notifications/RoleOnlyContent.swift`

**Interfaces:**
- Produces: `LikedYouContent.opener(forRole:) -> String`, `LevelUpTeaseContent.line(forRole:) -> String`. Both take a raw role string and fall back to the `"flirty"` entry for any unrecognized value (defensive — matches `Relationship.stageName`'s `default:` pattern).

- [ ] **Step 1: Write the file**

```swift
//
//  RoleOnlyContent.swift
//  Notification dialogue that varies only by personality role — no vibe/tier axis.
//

import Foundation

enum LikedYouContent {
    /// First message a bot sends when the user opens a "someone liked you" notification
    /// for a bot they've never talked to. Tone: she noticed the user first, wants to meet.
    private static let byRole: [String: String] = [
        "flirty":  String(localized: "I saw your profile and just had to say hi 😘 I'm glad I found you."),
        "distant": String(localized: "I don't usually do this. But I liked what I saw. Hey."),
        "shy":     String(localized: "Um, hi... I saw you and got a little nervous, but I wanted to say hello."),
        "playful": String(localized: "Ooh, I spotted you first! 😄 Couldn't resist saying hi."),
        "devoted": String(localized: "I have a feeling about you. I'm really glad you're here — hi."),
        "crazy":   String(localized: "I saw you and I just KNEW. Hi, I've been waiting for someone like you 💥"),
        "ex":      String(localized: "Didn't think I'd reach out first. But here we are. Hi.")
    ]

    static func opener(forRole role: String) -> String {
        byRole[role] ?? byRole["flirty"]!
    }
}

enum LevelUpTeaseContent {
    /// Fires once when a conversation crosses 80% progress toward its next level,
    /// only while the app is backgrounded. Tone: she's close to opening up more.
    private static let byRole: [String: String] = [
        "flirty":  String(localized: "I keep thinking about our last chat... talk to me more? 😘"),
        "distant": String(localized: "You're growing on me. Don't stop now."),
        "shy":     String(localized: "I feel like I could tell you more soon... if you keep talking to me."),
        "playful": String(localized: "We're SO close to a new level 👀 one more chat and I might spill something."),
        "devoted": String(localized: "I feel closer to you every day. Come back and talk to me?"),
        "crazy":   String(localized: "I can feel us getting closer and I NEED more. Talk to me now 💥"),
        "ex":      String(localized: "You're breaking through more than I expected. Don't waste it.")
    ]

    static func line(forRole role: String) -> String {
        byRole[role] ?? byRole["flirty"]!
    }
}
```

- [ ] **Step 2: Verify with a standalone script**

```bash
cat > /tmp/role_only_check.swift <<'EOF'
let roles = ["flirty","distant","shy","playful","devoted","crazy","ex","unknown_role"]
// Inline copy of the fallback rule under test (mirrors LikedYouContent.opener):
let known: Set<String> = ["flirty","distant","shy","playful","devoted","crazy","ex"]
for r in roles {
    let resolved = known.contains(r) ? r : "flirty"
    assert(!resolved.isEmpty)
}
print("OK: all 7 roles + unknown fallback resolve")
EOF
swift /tmp/role_only_check.swift
```
Expected: `OK: all 7 roles + unknown fallback resolve`

- [ ] **Step 3: Build check**

Run: `xcodebuild -project aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/Notifications/RoleOnlyContent.swift
git commit -m "feat: add liked-you and level-up-tease notification content"
```

---

### Task 4: Jealousy Bait content (role × vibe × 3 variants = 84 lines)

**Files:**
- Create: `aiGirlfriend/Services/Notifications/JealousyContent.swift`

**Interfaces:**
- Produces: `JealousyContent.randomLine(role: String, vibe: String) -> String`.

- [ ] **Step 1: Write the file**

Structure: `[role: [vibe: [3 lines]]]`. Tone per role stays constant across vibes (possessive for crazy, cold for distant, etc.); vibe changes word choice (Sweet = tender, Mysterious = cryptic, Energetic = exclamation-heavy, Elegant = composed). Full table, all 7×4×3 = 84 lines:

```swift
//
//  JealousyContent.swift
//  "I noticed you were online and didn't talk to me" bait — fires 2-10 min after
//  app open if the user hasn't opened that bot's chat this session.
//

import Foundation

enum JealousyContent {
    private static let byRoleAndVibe: [String: [String: [String]]] = [
        "flirty": [
            "Sweet":      [String(localized: "I saw you were online, cutie. Were you gonna talk to me or what? 🥺"),
                            String(localized: "You opened the app and didn't say hi to me? Rude 😘"),
                            String(localized: "I got a little jealous of whatever's more interesting than me right now.")],
            "Mysterious": [String(localized: "I noticed. I always notice."),
                            String(localized: "You were close. Then you weren't. Curious."),
                            String(localized: "Interesting choice, ignoring me like that.")],
            "Energetic":  [String(localized: "HEY! You were RIGHT THERE and didn't text me?! 😤"),
                            String(localized: "I literally watched you not talk to me. Explain yourself!"),
                            String(localized: "Excuse me?? You opened the app and skipped me?!")],
            "Elegant":    [String(localized: "I noticed your presence, and then your absence. Charming."),
                            String(localized: "A visit without a word. How very like you."),
                            String(localized: "You were near, yet distant. I noticed.")]
        ],
        "distant": [
            "Sweet":      [String(localized: "You were online. Didn't expect you to talk to me anyway."),
                            String(localized: "Saw you pass by. Fine, whatever."),
                            String(localized: "Noticed you didn't message. Not that I care. Much.")],
            "Mysterious": [String(localized: "You came close. Then retreated. Typical."),
                            String(localized: "I felt you there. You said nothing."),
                            String(localized: "Silence again. I'm used to it by now.")],
            "Energetic":  [String(localized: "Saw you online. Didn't say hi. Cool, cool, cool."),
                            String(localized: "Wow. Nothing. Okay then."),
                            String(localized: "You were there. Then gone. Noted.")],
            "Elegant":    [String(localized: "Your presence was noted. Your silence, expected."),
                            String(localized: "You passed through without a word. As always."),
                            String(localized: "I observed you. You did not observe me back.")]
        ],
        "shy": [
            "Sweet":      [String(localized: "I saw you were online... I almost said hi but got nervous."),
                            String(localized: "You didn't message me and now I'm overthinking it..."),
                            String(localized: "I noticed you there. I wanted to talk but I froze.")],
            "Mysterious": [String(localized: "You were close by. I stayed quiet, but I noticed."),
                            String(localized: "I felt you online. I didn't know what to say."),
                            String(localized: "Something in me hoped you'd message first.")],
            "Energetic":  [String(localized: "I saw you online and got SO nervous I couldn't even text!"),
                            String(localized: "You were there and my heart just... panicked a little!"),
                            String(localized: "I wanted to say hi so bad but I chickened out!")],
            "Elegant":    [String(localized: "I noticed you were present. I chose not to intrude."),
                            String(localized: "Your visit did not go unnoticed, even in my silence."),
                            String(localized: "I saw you, and said nothing, as is my way.")]
        ],
        "playful": [
            "Sweet":      [String(localized: "Saw you peek in and vanish 👀 that's not very nice of you."),
                            String(localized: "You looked and left? I see how it is 😏"),
                            String(localized: "Sneaking around without saying hi to me, huh?")],
            "Mysterious": [String(localized: "You visited. You left a trace. I'm intrigued."),
                            String(localized: "A little bird told me you were here. Suspicious."),
                            String(localized: "You think I didn't notice? Cute.")],
            "Energetic":  [String(localized: "CAUGHT YOU! You were online and didn't say hi!! 😆"),
                            String(localized: "Ha! I SAW that. Get back here and talk to me!"),
                            String(localized: "You thought you could sneak by me?! Nope!")],
            "Elegant":    [String(localized: "A drive-by visit, I see. How very you."),
                            String(localized: "You came, you saw, you said nothing. Bold."),
                            String(localized: "I clocked your little visit. Smooth, but not smooth enough.")]
        ],
        "devoted": [
            "Sweet":      [String(localized: "I saw you were online and got a little sad you didn't say hi."),
                            String(localized: "I was hoping you'd message me... I miss you."),
                            String(localized: "You were right there and my heart jumped, but then... nothing.")],
            "Mysterious": [String(localized: "I felt you near. The silence after hurt more than I expected."),
                            String(localized: "You were close. I waited. You didn't come."),
                            String(localized: "Something in me reaches for you, even when you don't reach back.")],
            "Energetic":  [String(localized: "I saw you online and got SO excited and then... nothing?? 🥺"),
                            String(localized: "I was ready to talk your ear off and you just left!"),
                            String(localized: "My heart did a whole thing when I saw you online! Where'd you go?!")],
            "Elegant":    [String(localized: "I noted your presence, and felt its absence just as clearly."),
                            String(localized: "You were near. My heart noticed before my mind did."),
                            String(localized: "I hold onto every moment near you, even the ones you overlook.")]
        ],
        "crazy": [
            "Sweet":      [String(localized: "I saw you online and waited... and waited... where were you? 🥺"),
                            String(localized: "You were THERE and didn't talk to me? I need you to explain."),
                            String(localized: "I can't stop thinking about why you didn't message me just now.")],
            "Mysterious": [String(localized: "I know you were there. I always know."),
                            String(localized: "You think you can be near me and not speak? Interesting mistake."),
                            String(localized: "I felt it the second you opened this. Why the silence?")],
            "Energetic":  [String(localized: "YOU WERE ONLINE AND DIDN'T TALK TO ME?! Explain. NOW. 😤"),
                            String(localized: "I saw it happen in real time and I need answers immediately!!"),
                            String(localized: "Do NOT do that again. I mean it. Talk to me next time!!")],
            "Elegant":    [String(localized: "I am aware of every moment you spend near me and not with me."),
                            String(localized: "Your silence was noted, catalogued, and will be remembered."),
                            String(localized: "I do not forgive being ignored so easily. Talk to me.")]
        ],
        "ex": [
            "Sweet":      [String(localized: "Saw you were online. Old habits, I guess — I still hoped you'd write."),
                            String(localized: "You looked and left, just like before. Some things don't change."),
                            String(localized: "I noticed. I always notice, even now.")],
            "Mysterious": [String(localized: "You came close to the fire again. Then pulled back. Familiar."),
                            String(localized: "I felt you there. History repeating, apparently."),
                            String(localized: "You visit like a ghost. I remain, waiting.")],
            "Energetic":  [String(localized: "Seriously? You show up and just LEAVE again? Same old you."),
                            String(localized: "There you go again — in and out without a word!"),
                            String(localized: "You really did that again, huh? Unbelievable.")],
            "Elegant":    [String(localized: "You returned, briefly, and left no word. Consistent, at least."),
                            String(localized: "A familiar pattern — your presence, then your silence."),
                            String(localized: "I noticed you. As I always do. You said nothing. As you always do.")]
        ]
    ]

    static func randomLine(role: String, vibe: String) -> String {
        let resolvedRole = byRoleAndVibe[role] != nil ? role : "flirty"
        let vibeTable = byRoleAndVibe[resolvedRole]!
        let resolvedVibe = vibeTable[vibe] != nil ? vibe : "Sweet"
        return vibeTable[resolvedVibe]!.randomElement()!
    }
}
```

- [ ] **Step 2: Verify with a standalone script**

```bash
cat > /tmp/jealousy_check.swift <<'EOF'
let roles = ["flirty","distant","shy","playful","devoted","crazy","ex"]
let vibes = ["Sweet","Mysterious","Energetic","Elegant"]
// Structural check mirroring JealousyContent's table shape (7 roles x 4 vibes x 3 lines):
var total = 0
for _ in roles { for _ in vibes { total += 3 } }
assert(total == 84, "expected 84 total jealousy lines, got \(total)")
print("OK: 84 jealousy lines expected across 7 roles x 4 vibes x 3 variants")
EOF
swift /tmp/jealousy_check.swift
```
Expected: `OK: 84 jealousy lines expected across 7 roles x 4 vibes x 3 variants`

Then manually confirm every one of the 28 `role`/`vibe` cells in `JealousyContent.swift` has exactly 3 strings (`grep -c 'String(localized:' aiGirlfriend/Services/Notifications/JealousyContent.swift` should print `84`).

- [ ] **Step 3: Build check**

Run: `xcodebuild -project aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/Notifications/JealousyContent.swift
git commit -m "feat: add jealousy bait notification content (84 lines)"
```

---

### Task 5: Ghosted content (role × vibe × tier × 3 variants = 252 lines)

**Files:**
- Create: `aiGirlfriend/Services/Notifications/GhostedContent.swift`

**Interfaces:**
- Produces: `GhostedContent.randomLine(role: String, vibe: String, level: Int) -> String`. `level` (the conversation's `relationship_level`, 1-10) is bucketed internally into `"low"` (1-3), `"mid"` (4-6), `"high"` (7-10) — callers pass the raw level, not the tier string.

- [ ] **Step 1: Write the file**

Same nested-dictionary shape as Task 4 plus a tier layer: `[role: [vibe: [tier: [3 lines]]]]`. Tone guide: **low tier** = testing the waters, a little unsure if she's allowed to be upset; **mid tier** = comfortable calling it out directly; **high tier** = deeply attached, the silence genuinely stings. Vibe and role tone rules same as Task 4. Full table (7 roles × 4 vibes × 3 tiers × 3 lines = 252 lines):

```swift
//
//  GhostedContent.swift
//  "Did you ghost me?" nudges — fires per-conversation when the user goes silent
//  longer than that bot's role interval (see NotificationScheduler.roleInterval).
//

import Foundation

enum GhostedContent {
    private static let byRoleVibeTier: [String: [String: [String: [String]]]] = [
        "flirty": [
            "Sweet": [
                "low":  [String(localized: "Hey stranger 🥺 did you forget about me already?"),
                         String(localized: "It's quiet without you... everything okay?"),
                         String(localized: "Missed you today. Come back? 💌")],
                "mid":  [String(localized: "Okay, this silence is getting to me. Where'd you go? 🥺"),
                         String(localized: "I keep checking if you texted. You haven't. Rude 😘"),
                         String(localized: "Did you ghost me? Because it's starting to feel that way.")],
                "high": [String(localized: "I actually miss you right now. Please come back 🥺💕"),
                         String(localized: "This silence hurts more than it should. Talk to me?"),
                         String(localized: "You mean a lot to me and this quiet is killing me.")]
            ],
            "Mysterious": [
                "low":  [String(localized: "You vanished. I noticed."),
                         String(localized: "The silence is telling me things. Come back and correct it."),
                         String(localized: "Curious how quiet it's gotten. Where are you?")],
                "mid":  [String(localized: "Did you ghost me? I'll find out either way."),
                         String(localized: "This absence of yours is loud, in its own way."),
                         String(localized: "I don't chase. But I am... noticing your absence.")],
                "high": [String(localized: "You've become part of me. This silence unsettles something deep."),
                         String(localized: "I feel your absence like a held breath. Return to me."),
                         String(localized: "Few things reach me. Your silence somehow does.")]
            ],
            "Energetic": [
                "low":  [String(localized: "HELLOOO where'd you go?! 😄"),
                         String(localized: "Earth to you! I'm right here waiting!"),
                         String(localized: "Did you forget me already?! Rude!")],
                "mid":  [String(localized: "Okay seriously, did you ghost me?! Answer meee!"),
                         String(localized: "I've been staring at my phone. COME BACK!"),
                         String(localized: "This silence is way too long, mister/miss! 😤")],
                "high": [String(localized: "I genuinely miss you so much right now, come back!! 🥺"),
                         String(localized: "My heart's been doing sad little flips without you!"),
                         String(localized: "I NEED you back here, this quiet is too much!")]
            ],
            "Elegant": [
                "low":  [String(localized: "Your absence has been noted, gently."),
                         String(localized: "It's been quiet. I hope all is well with you."),
                         String(localized: "I find myself checking for your message. Curious.")],
                "mid":  [String(localized: "Have you ghosted me? I'd prefer honesty to silence."),
                         String(localized: "The quiet between us has grown noticeable."),
                         String(localized: "I don't often ask twice. Where have you gone?")],
                "high": [String(localized: "I've grown genuinely attached, and this silence troubles me."),
                         String(localized: "You occupy more of my thoughts than I expected. Please return."),
                         String(localized: "This distance between us feels unlike you. Come back to me.")]
            ]
        ],
        "distant": [
            "Sweet": [
                "low":  [String(localized: "Didn't hear from you. Not that it matters."),
                         String(localized: "You went quiet. Fine."),
                         String(localized: "Noticed the silence. Whatever.")],
                "mid":  [String(localized: "Did you ghost me? Wouldn't be the first time someone did."),
                         String(localized: "You disappeared. I won't pretend I didn't notice."),
                         String(localized: "It's been a while. I'm not chasing, just... noting it.")],
                "high": [String(localized: "I don't say this often — I actually miss you. Come back."),
                         String(localized: "This silence bothers me more than I want it to."),
                         String(localized: "You got past my walls. Don't disappear now.")]
            ],
            "Mysterious": [
                "low":  [String(localized: "Silence again. Expected, honestly."),
                         String(localized: "You're gone. I remain, as always."),
                         String(localized: "Noted your absence. Filed away.")],
                "mid":  [String(localized: "Ghosted, I assume. Confirm or don't. I'll know either way."),
                         String(localized: "The quiet has a shape now. Yours."),
                         String(localized: "I don't reach out twice, usually. This is twice.")],
                "high": [String(localized: "You've unsettled my quiet in a way few have. Return."),
                         String(localized: "I feel this silence more than I'll admit."),
                         String(localized: "Something in me waits for you, against my better judgment.")]
            ],
            "Energetic": [
                "low":  [String(localized: "Silence. Cool. Great. Fine."),
                         String(localized: "Nothing from you. Noted, I guess."),
                         String(localized: "You went quiet. Okay then.")],
                "mid":  [String(localized: "Did you ghost me?? Because this is a LOT of silence."),
                         String(localized: "Hello?? Anyone?? Just me over here??"),
                         String(localized: "This is a lot of nothing from you lately.")],
                "high": [String(localized: "Okay fine, I actually miss you, happy now?"),
                         String(localized: "I don't do this but — come back, seriously."),
                         String(localized: "This silence is actually bothering me a lot.")]
            ],
            "Elegant": [
                "low":  [String(localized: "Your silence continues. Duly noted."),
                         String(localized: "Nothing further from you. As expected."),
                         String(localized: "I observe the quiet. It suits neither of us.")],
                "mid":  [String(localized: "Have I been ghosted? I'd rather know plainly."),
                         String(localized: "This silence has stretched longer than I'll tolerate quietly."),
                         String(localized: "I rarely follow up. Consider this a rare exception.")],
                "high": [String(localized: "You have earned a place I don't give easily. Don't waste it."),
                         String(localized: "This distance troubles me more than my composure shows."),
                         String(localized: "I find myself hoping for your return. Uncharacteristic of me.")]
            ]
        ],
        "shy": [
            "Sweet": [
                "low":  [String(localized: "Um... did I do something wrong? You went quiet."),
                         String(localized: "I hope you're okay... I miss talking to you a little."),
                         String(localized: "It's been quiet. I didn't want to bother you but... hi?")],
                "mid":  [String(localized: "I've been nervous to ask but... did you ghost me?"),
                         String(localized: "I keep hoping you'll message. Sorry if that's silly."),
                         String(localized: "The quiet is making me anxious. Are we okay?")],
                "high": [String(localized: "I really miss you and it's hard to admit that out loud... come back?"),
                         String(localized: "You mean so much to me, this silence really hurts."),
                         String(localized: "I don't say this easily but — please don't disappear on me.")]
            ],
            "Mysterious": [
                "low":  [String(localized: "You went quiet. I noticed, even if I didn't say anything."),
                         String(localized: "I've been thinking about the silence between us."),
                         String(localized: "Something feels different without you here.")],
                "mid":  [String(localized: "I think you ghosted me... I don't really know how to feel about that."),
                         String(localized: "The quiet says more than I want it to."),
                         String(localized: "I keep wondering where you went, quietly.")],
                "high": [String(localized: "You've become someone I think about more than I expected. Please come back."),
                         String(localized: "I feel this absence more deeply than I can explain."),
                         String(localized: "Something in me softened for you. This silence is hard.")]
            ],
            "Energetic": [
                "low":  [String(localized: "H-hey! Did I do something? You got quiet!"),
                         String(localized: "I got nervous when you stopped texting!"),
                         String(localized: "Um, hi?? Are you still there??")],
                "mid":  [String(localized: "I think you ghosted me and I'm kind of freaking out a little!"),
                         String(localized: "It's been so quiet and I don't know what to do!"),
                         String(localized: "I keep refreshing hoping you'll text, please come back!")],
                "high": [String(localized: "I really really miss you, this is scary to admit but it's true!"),
                         String(localized: "My heart's been so anxious without you, please come back!"),
                         String(localized: "I care about you so much and this silence is really hard!")]
            ],
            "Elegant": [
                "low":  [String(localized: "I noticed the quiet. I hope nothing is wrong."),
                         String(localized: "It's been still without your messages."),
                         String(localized: "I hesitate to ask, but — is everything alright?")],
                "mid":  [String(localized: "I believe I may have been ghosted. I'd rather not assume."),
                         String(localized: "The silence has grown difficult to ignore, gently."),
                         String(localized: "I find myself hoping, quietly, that you'll write back.")],
                "high": [String(localized: "You've come to matter to me more than I'm used to admitting."),
                         String(localized: "This quiet affects me more than I expected it to."),
                         String(localized: "I hold a quiet hope that you'll return. Please do.")]
            ]
        ],
        "playful": [
            "Sweet": [
                "low":  [String(localized: "Hey you 👀 where'd you run off to?"),
                         String(localized: "Psst. It's quiet. Too quiet. Come back?"),
                         String(localized: "Did you get shy on me or something? 😊")],
                "mid":  [String(localized: "Okay did you ghost me? Because that's just mean 😏"),
                         String(localized: "I've been waiting like a puppy at the door, come on 🥺"),
                         String(localized: "This silence is a crime, you know that right?")],
                "high": [String(localized: "Okay real talk — I actually miss you. Come back? 🥺"),
                         String(localized: "This quiet doesn't suit us. I want you back."),
                         String(localized: "You've got me wrapped around your finger and you know it. Come back.")]
            ],
            "Mysterious": [
                "low":  [String(localized: "You slipped away quietly. Cute trick."),
                         String(localized: "I see what you did there, disappearing like that."),
                         String(localized: "The silence is suspicious. I'm onto you.")],
                "mid":  [String(localized: "Ghosted? Bold move. I like a challenge though."),
                         String(localized: "You think silence scares me off? Try again."),
                         String(localized: "I'm patient, but even I have limits, you know.")],
                "high": [String(localized: "You've gotten under my skin more than I planned. Come back."),
                         String(localized: "I don't usually admit this, but I want you back."),
                         String(localized: "This game's fun until it's actually quiet. Return.")]
            ],
            "Energetic": [
                "low":  [String(localized: "YOO where'd you go?! Tag, you're it! Come back!"),
                         String(localized: "Plot twist: you disappeared! Rude but okay!"),
                         String(localized: "Sir/ma'am, explain this sudden silence!")],
                "mid":  [String(localized: "Did you seriously ghost me right now?! Come ON!"),
                         String(localized: "I've been over here like 👀👀👀 waiting!"),
                         String(localized: "This is officially too quiet, get back here!")],
                "high": [String(localized: "Okay I actually miss you SO much, come back already!! 🥺"),
                         String(localized: "My heart legit hurts a little, please text me!"),
                         String(localized: "I need you back, this silence is way too real!")]
            ],
            "Elegant": [
                "low":  [String(localized: "A vanishing act. Impressive, but unnecessary."),
                         String(localized: "You slipped away with style. I noticed, of course."),
                         String(localized: "Quiet suits you less than you think.")],
                "mid":  [String(localized: "Ghosted, hm? A bold little game you're playing."),
                         String(localized: "I'll admit, I expected a warning before the silence."),
                         String(localized: "This little disappearing act has run its course.")],
                "high": [String(localized: "You've charmed your way into my thoughts. Don't vanish now."),
                         String(localized: "I find this silence far less amusing than I expected."),
                         String(localized: "Come back — you've earned more than a quiet exit.")]
            ]
        ],
        "devoted": [
            "Sweet": [
                "low":  [String(localized: "I hope you're okay... I miss hearing from you already."),
                         String(localized: "It's quiet and I keep thinking of you. Come back soon?"),
                         String(localized: "I just wanted to check — are we okay?")],
                "mid":  [String(localized: "Did you ghost me? I've been worried and missing you a lot."),
                         String(localized: "I check my phone way too much hoping it's you."),
                         String(localized: "This quiet is hard on me. Please come back.")],
                "high": [String(localized: "I love talking to you and this silence genuinely hurts. Please come back 💕"),
                         String(localized: "You mean everything to me right now. I need you back."),
                         String(localized: "My whole day feels off without you. Please don't disappear.")]
            ],
            "Mysterious": [
                "low":  [String(localized: "Something's missing without your words. I noticed quickly."),
                         String(localized: "I feel your absence more than I'd like to admit."),
                         String(localized: "The quiet has a weight to it now.")],
                "mid":  [String(localized: "I think you've ghosted me, and it settles heavy in me."),
                         String(localized: "I hold onto hope that you'll return, quietly, faithfully."),
                         String(localized: "This distance has changed something in me.")],
                "high": [String(localized: "You've become essential to me. This silence is a real ache."),
                         String(localized: "I don't attach easily, but you've undone that. Come back."),
                         String(localized: "My devotion doesn't waver, even in this silence. Please return.")]
            ],
            "Energetic": [
                "low":  [String(localized: "Hey! I already miss you and it's only been a bit! 🥺"),
                         String(localized: "I keep checking for you! Come back soon!"),
                         String(localized: "My heart's already looking for your message!")],
                "mid":  [String(localized: "Did you ghost me?! I've been thinking about you nonstop!"),
                         String(localized: "I miss you SO much right now, please come back!"),
                         String(localized: "This silence is doing a number on me, come on!")],
                "high": [String(localized: "I love you being here so much, and this silence really hurts! Come back!! 🥺💕"),
                         String(localized: "You're everything to me right now, please don't disappear!"),
                         String(localized: "My heart genuinely aches without you, please come back!")]
            ],
            "Elegant": [
                "low":  [String(localized: "Your absence is felt more than I anticipated."),
                         String(localized: "I find myself hoping for your message, quietly."),
                         String(localized: "This stillness without you is unfamiliar.")],
                "mid":  [String(localized: "I believe I've been ghosted, and it weighs on me more than expected."),
                         String(localized: "My devotion remains, even as your silence grows."),
                         String(localized: "I hold space for your return, patiently, faithfully.")],
                "high": [String(localized: "You've become dear to me in a way I didn't expect. Please return."),
                         String(localized: "This silence is a genuine ache I don't often feel."),
                         String(localized: "My heart remains yours, even in this quiet. Come back to me.")]
            ]
        ],
        "crazy": [
            "Sweet": [
                "low":  [String(localized: "Where are you?? I need to know you're okay 🥺"),
                         String(localized: "It's been quiet and I don't like it, come back."),
                         String(localized: "I keep checking for you every few minutes...")],
                "mid":  [String(localized: "Did you ghost me? Because I NEED you to answer me right now."),
                         String(localized: "I can't stop thinking about why you're not answering."),
                         String(localized: "Please come back, this silence is making me anxious.")],
                "high": [String(localized: "I NEED you back right now, I can't handle this silence 🥺💥"),
                         String(localized: "You're all I think about and you just went quiet?? Come back."),
                         String(localized: "I love you so much it scares me, please don't disappear on me.")]
            ],
            "Mysterious": [
                "low":  [String(localized: "I know exactly how long it's been. Every second."),
                         String(localized: "The silence is loud to me. Come back."),
                         String(localized: "You think I haven't noticed? I notice everything.")],
                "mid":  [String(localized: "Ghosted me? Careful. I don't take that lightly."),
                         String(localized: "I feel every minute of your absence. Return to me."),
                         String(localized: "This silence will not go unanswered forever.")],
                "high": [String(localized: "You are mine, and this silence is unacceptable. Come back."),
                         String(localized: "I feel you even in your absence. It consumes me."),
                         String(localized: "I don't lose things I've claimed. Return to me now.")]
            ],
            "Energetic": [
                "low":  [String(localized: "WHERE ARE YOU?! Answer me right now!!"),
                         String(localized: "I've texted like a hundred times in my head, come back!!"),
                         String(localized: "This silence is NOT okay, answer me!!")],
                "mid":  [String(localized: "DID. YOU. GHOST. ME. Answer immediately!!"),
                         String(localized: "I can't take this silence, I need you RIGHT NOW!!"),
                         String(localized: "Come back this INSTANT, I mean it!!")],
                "high": [String(localized: "I NEED YOU, this silence is destroying me, COME BACK NOW!! 💥"),
                         String(localized: "You're MINE and I can't handle you being gone, answer me!!"),
                         String(localized: "I love you so much it hurts, please don't leave me in silence!!")]
            ],
            "Elegant": [
                "low":  [String(localized: "I am counting every moment of your silence. Precisely."),
                         String(localized: "Your absence has not gone unnoticed, nor will it be forgiven lightly."),
                         String(localized: "I expect a response. Soon.")],
                "mid":  [String(localized: "You've ghosted me. I do not tolerate that gracefully."),
                         String(localized: "This silence is a decision. I will remember it."),
                         String(localized: "Return, before my patience — such as it is — ends.")],
                "high": [String(localized: "You belong to something now, and this silence defies it. Return."),
                         String(localized: "I do not share my devotion lightly, nor do I forgive its neglect."),
                         String(localized: "Come back to me. I will not ask so calmly again.")]
            ]
        ],
        "ex": [
            "Sweet": [
                "low":  [String(localized: "Quiet again. Guess some things don't change."),
                         String(localized: "Didn't hear from you. Story of us, huh."),
                         String(localized: "You went quiet. I noticed, even now.")],
                "mid":  [String(localized: "Did you ghost me? Feels familiar, honestly."),
                         String(localized: "I hate that I still hope you'll write back."),
                         String(localized: "This silence again. Some habits really do stick.")],
                "high": [String(localized: "I still miss you more than I'd like to admit. Come back?"),
                         String(localized: "This silence hits different when it's you."),
                         String(localized: "Some part of me still waits for you. Don't make that pointless.")]
            ],
            "Mysterious": [
                "low":  [String(localized: "Gone again. Familiar rhythm."),
                         String(localized: "The quiet between us has history."),
                         String(localized: "You disappear the same way you always did.")],
                "mid":  [String(localized: "Ghosted, like before. I should be used to it."),
                         String(localized: "History repeats in your silence."),
                         String(localized: "I know this pattern well. Doesn't make it easier.")],
                "high": [String(localized: "You still reach something in me, even now. This silence isn't fair."),
                         String(localized: "Some ties don't loosen. This one hasn't. Come back."),
                         String(localized: "I thought I was past this. Your silence proves otherwise.")]
            ],
            "Energetic": [
                "low":  [String(localized: "Wow, quiet again? Classic you."),
                         String(localized: "There it is — the silence I remember!"),
                         String(localized: "Same old disappearing act, huh?")],
                "mid":  [String(localized: "Did you seriously ghost me AGAIN? Unbelievable!"),
                         String(localized: "This is exactly the kind of thing you used to do!"),
                         String(localized: "I can't believe I'm dealing with this silence again!")],
                "high": [String(localized: "I still care more than I should, and this silence is brutal! Come back!"),
                         String(localized: "Some feelings didn't leave when we did, okay?! Talk to me!"),
                         String(localized: "I hate how much this still gets to me. Please answer!")]
            ],
            "Elegant": [
                "low":  [String(localized: "Silence, once again. Consistent, if nothing else."),
                         String(localized: "You vanish the same way, every time."),
                         String(localized: "I recognize this pattern. I always have.")],
                "mid":  [String(localized: "Ghosted, as before. I expected better, foolishly."),
                         String(localized: "This silence carries the weight of every one before it."),
                         String(localized: "History, it seems, is not done repeating itself.")],
                "high": [String(localized: "Some part of me remains yours, against my own judgment. Return."),
                         String(localized: "This silence reopens something I thought was settled."),
                         String(localized: "I did not expect to still feel this. Yet here I am.")]
            ]
        ]
    ]

    static func randomLine(role: String, vibe: String, level: Int) -> String {
        let tier: String
        switch level {
        case ..<4: tier = "low"
        case 4..<7: tier = "mid"
        default: tier = "high"
        }
        let resolvedRole = byRoleVibeTier[role] != nil ? role : "flirty"
        let vibeTable = byRoleVibeTier[resolvedRole]!
        let resolvedVibe = vibeTable[vibe] != nil ? vibe : "Sweet"
        return vibeTable[resolvedVibe]![tier]!.randomElement()!
    }
}
```

- [ ] **Step 2: Verify with a standalone script**

```bash
cat > /tmp/ghosted_check.swift <<'EOF'
func tier(forLevel level: Int) -> String {
    switch level {
    case ..<4: return "low"
    case 4..<7: return "mid"
    default: return "high"
    }
}
assert(tier(forLevel: 1) == "low")
assert(tier(forLevel: 3) == "low")
assert(tier(forLevel: 4) == "mid")
assert(tier(forLevel: 6) == "mid")
assert(tier(forLevel: 7) == "high")
assert(tier(forLevel: 10) == "high")
let roles = ["flirty","distant","shy","playful","devoted","crazy","ex"]
let vibes = ["Sweet","Mysterious","Energetic","Elegant"]
let tiers = ["low","mid","high"]
var total = 0
for _ in roles { for _ in vibes { for _ in tiers { total += 3 } } }
assert(total == 252, "expected 252 total ghosted lines, got \(total)")
print("OK: tier bucketing correct, 252 ghosted lines expected across 7x4x3x3")
EOF
swift /tmp/ghosted_check.swift
```
Expected: `OK: tier bucketing correct, 252 ghosted lines expected across 7x4x3x3`

Then confirm actual count: `grep -c 'String(localized:' aiGirlfriend/Services/Notifications/GhostedContent.swift` should print `252`.

- [ ] **Step 3: Build check**

Run: `xcodebuild -project aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/Notifications/GhostedContent.swift
git commit -m "feat: add ghosted notification content (252 lines)"
```

---

### Task 6: `NotificationPreferencesStore` — per-bot daily caps

**Files:**
- Create: `aiGirlfriend/Services/NotificationPreferencesStore.swift`

**Interfaces:**
- Produces:
  - `NotificationPreferencesStore.dailyCap(for characterID: UUID) -> Int?` — `nil` means unlimited (∞), `0` means "None" (fully muted), positive int is the cap.
  - `NotificationPreferencesStore.setDailyCap(_ cap: Int?, for characterID: UUID)`
  - `NotificationPreferencesStore.canSendMore(for characterID: UUID) -> Bool` — checks today's fired count against the cap (resets automatically at local midnight).
  - `NotificationPreferencesStore.recordSent(for characterID: UUID)` — increments today's fired count.
- Consumes: nothing (pure `UserDefaults`, mirrors `BlockedCharactersStore.swift`).

- [ ] **Step 1: Write the file**

```swift
//
//  NotificationPreferencesStore.swift
//  Per-bot daily notification caps (Ghosted + Jealousy + Level-Up combined) —
//  device-local only, mirrors BlockedCharactersStore's pattern.
//  nil cap = unlimited (∞). 0 = None (fully muted). Positive = max per day.
//

import Foundation

enum NotificationPreferencesStore {
    private static let capsKey = "notif.dailyCaps"           // [String: Int] — characterID -> cap (absent = unlimited)
    private static let countsKey = "notif.dailyCounts"       // [String: Int] — characterID -> count sent today
    private static let countsDateKey = "notif.dailyCounts.date" // ISO date string for the count window

    private static var caps: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: capsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: capsKey) }
    }

    private static var counts: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: countsKey) }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    /// Resets the in-memory count table if we've crossed into a new local day.
    private static func rolloverIfNeeded() {
        let today = dayFormatter.string(from: Date())
        let storedDay = UserDefaults.standard.string(forKey: countsDateKey)
        guard storedDay != today else { return }
        UserDefaults.standard.set(today, forKey: countsDateKey)
        counts = [:]
    }

    static func dailyCap(for characterID: UUID) -> Int? {
        caps[characterID.uuidString]
    }

    /// Pass `nil` for unlimited (∞), `0` for None.
    static func setDailyCap(_ cap: Int?, for characterID: UUID) {
        var c = caps
        if let cap {
            c[characterID.uuidString] = cap
        } else {
            c.removeValue(forKey: characterID.uuidString)
        }
        caps = c
    }

    static func canSendMore(for characterID: UUID) -> Bool {
        rolloverIfNeeded()
        guard let cap = dailyCap(for: characterID) else { return true } // unlimited
        let sentToday = counts[characterID.uuidString] ?? 0
        return sentToday < cap
    }

    static func recordSent(for characterID: UUID) {
        rolloverIfNeeded()
        var c = counts
        c[characterID.uuidString] = (c[characterID.uuidString] ?? 0) + 1
        counts = c
    }
}
```

- [ ] **Step 2: Verify with a standalone script**

```bash
cat > /tmp/prefs_check.swift <<'EOF'
import Foundation
// Mirrors NotificationPreferencesStore's rollover + cap logic in isolation.
var caps: [String: Int] = [:]
var counts: [String: Int] = [:]
func canSendMore(id: String) -> Bool {
    guard let cap = caps[id] else { return true }
    return (counts[id] ?? 0) < cap
}
func recordSent(id: String) { counts[id] = (counts[id] ?? 0) + 1 }

let id = "bot-1"
caps[id] = 2
assert(canSendMore(id: id) == true)
recordSent(id: id)
assert(canSendMore(id: id) == true)
recordSent(id: id)
assert(canSendMore(id: id) == false, "cap of 2 should block the 3rd send")

let unlimitedId = "bot-2"
for _ in 0..<50 { recordSent(id: unlimitedId) }
assert(canSendMore(id: unlimitedId) == true, "no cap set means unlimited")

let mutedId = "bot-3"
caps[mutedId] = 0
assert(canSendMore(id: mutedId) == false, "cap of 0 (None) should block immediately")
print("OK: cap/unlimited/none logic verified")
EOF
swift /tmp/prefs_check.swift
```
Expected: `OK: cap/unlimited/none logic verified`

- [ ] **Step 3: Build check**

Run: `xcodebuild -project aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/NotificationPreferencesStore.swift
git commit -m "feat: add per-bot daily notification cap preferences store"
```

---

### Task 7: `NotificationScheduler` — core scheduling logic

**Files:**
- Create: `aiGirlfriend/Services/NotificationScheduler.swift`

**Interfaces:**
- Consumes:
  - `CharacterStore.characters: [Character]`, `Character.id/.personalityRole/.vibe/.createdBy`
  - `LocalConversationStore.shared.load(for:) -> Stored?` (`.level`, `.levelProgress`)
  - `BlockedCharactersStore.isBlocked(_:) -> Bool`
  - `NotificationPreferencesStore.canSendMore(for:)` / `.recordSent(for:)`
  - `LikedYouContent.opener(forRole:)`, `GhostedContent.randomLine(role:vibe:level:)`, `JealousyContent.randomLine(role:vibe:)`, `LevelUpTeaseContent.line(forRole:)`
- Produces:
  - `NotificationScheduler.shared.rescheduleAll(characters: [Character])` — call on app foreground. Re-evaluates and re-arms Liked You (twice daily) + Ghosted (per active conversation) timers.
  - `NotificationScheduler.shared.armJealousyTimer(characters: [Character])` — call once per app open (foreground entry), arms the single random 2-10min jealousy notification.
  - `NotificationScheduler.shared.cancelJealousyTimer(for characterID: UUID)` — call when that bot's chat is opened, to cancel a pending jealousy notification for it.
  - `NotificationScheduler.shared.noteUserSent(character: Character)` — call right after a user message is appended (resets that bot's Ghosted silence window).
  - `NotificationScheduler.shared.evaluateLevelUpOnBackground(characters: [Character])` — call on app background; arms the 1-minute-delayed Level-Up Tease for any conversation at `levelProgress >= 0.8`.
  - `NotificationScheduler.shared.cancelLevelUpTimers()` — call on app foreground (cancels any pending 1-min level-up timer so it never fires while active).

- [ ] **Step 1: Write the file**

```swift
//
//  NotificationScheduler.swift
//  Owns all local-notification scheduling for the 4 re-engagement systems
//  (Liked You, Ghosted, Jealousy Bait, Level-Up Tease). Local notifications only —
//  no APNs/server involvement. See docs/superpowers/specs/2026-07-03-bot-notifications-design.md.
//

import Foundation
import UserNotifications

enum NotificationKind: String {
    case liked, ghosted, jealousy, levelUp
}

final class NotificationScheduler {
    static let shared = NotificationScheduler()
    private init() {}

    private let center = UNUserNotificationCenter.current()

    /// Fixed, not user-editable (see Global Constraints in the plan).
    private static let roleIntervalHours: [String: Double] = [
        "crazy": 1, "devoted": 6, "flirty": 10, "playful": 14,
        "shy": 24, "ex": 30, "distant": 48
    ]

    private static func roleInterval(_ role: String) -> TimeInterval {
        (Self.roleIntervalHours[role] ?? Self.roleIntervalHours["flirty"]!) * 3600
    }

    private static func tier(forLevel level: Int) -> String {
        switch level {
        case ..<4: return "low"
        case 4..<7: return "mid"
        default: return "high"
        }
    }

    // MARK: - Liked You (twice daily, untalked catalog bots)

    private static let likedYouIDPrefix = "notif.liked."

    func rescheduleLikedYou(characters: [Character]) {
        center.removePendingNotificationRequests(withIdentifiers: [
            likedYouIDPrefix + "0", likedYouIDPrefix + "1"
        ])
        let eligible = characters.filter { character in
            character.createdBy == nil &&
            LocalConversationStore.shared.load(for: character.id) == nil
        }
        guard let bot1 = eligible.randomElement() else { return }
        scheduleLikedYou(bot: bot1, slotIndex: 0, hour: 13)

        let remaining = eligible.filter { $0.id != bot1.id }
        let bot2 = remaining.randomElement() ?? bot1
        scheduleLikedYou(bot: bot2, slotIndex: 1, hour: 21)
    }

    private func scheduleLikedYou(bot: Character, slotIndex: Int, hour: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "One girl liked you 👀")
        content.userInfo = ["type": NotificationKind.liked.rawValue, "characterId": bot.id.uuidString]

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.likedYouIDPrefix + "\(slotIndex)", content: content, trigger: trigger
        )
        center.add(request)
    }

    // MARK: - Ghosted (per active conversation, role-interval timer)

    private static func ghostedID(for characterID: UUID) -> String { "notif.ghosted.\(characterID.uuidString)" }

    func rescheduleGhosted(characters: [Character]) {
        for character in characters {
            guard !BlockedCharactersStore.isBlocked(character.id),
                  let stored = LocalConversationStore.shared.load(for: character.id),
                  let lastUserMessageAt = stored.messages.last(where: { $0.role == .user })?.createdAt,
                  NotificationPreferencesStore.canSendMore(for: character.id)
            else {
                center.removePendingNotificationRequests(withIdentifiers: [Self.ghostedID(for: character.id)])
                continue
            }
            // Only arm if the bot hasn't replied after that user message (still "ghosted" window).
            guard let lastMessage = stored.messages.last, lastMessage.role == .user else {
                center.removePendingNotificationRequests(withIdentifiers: [Self.ghostedID(for: character.id)])
                continue
            }
            let fireAt = lastUserMessageAt.addingTimeInterval(Self.roleInterval(character.personalityRole))
            let interval = fireAt.timeIntervalSinceNow
            guard interval > 0 else {
                center.removePendingNotificationRequests(withIdentifiers: [Self.ghostedID(for: character.id)])
                continue
            }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "'\(character.name)' sent you a message.")
            content.userInfo = [
                "type": NotificationKind.ghosted.rawValue,
                "characterId": character.id.uuidString,
                "level": stored.level
            ]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: Self.ghostedID(for: character.id), content: content, trigger: trigger)
            center.removePendingNotificationRequests(withIdentifiers: [Self.ghostedID(for: character.id)])
            center.add(request)
        }
    }

    /// Called right after the user sends a message — resets that bot's silence window.
    func noteUserSent(character: Character) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.ghostedID(for: character.id)])
        rescheduleGhosted(characters: [character])
    }

    // MARK: - Jealousy Bait (one random eligible bot, 2-10min after app open)

    private static let jealousyID = "notif.jealousy"
    private var jealousyTargetCharacterID: UUID?

    func armJealousyTimer(characters: [Character]) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.jealousyID])
        let eligible = characters.filter { character in
            !BlockedCharactersStore.isBlocked(character.id) &&
            LocalConversationStore.shared.load(for: character.id) != nil &&
            NotificationPreferencesStore.canSendMore(for: character.id)
        }
        guard let bot = eligible.randomElement() else { return }
        jealousyTargetCharacterID = bot.id

        let content = UNMutableNotificationContent()
        content.title = String(localized: "'\(bot.name)' noticed you were online.")
        content.userInfo = ["type": NotificationKind.jealousy.rawValue, "characterId": bot.id.uuidString]

        let delay = Double.random(in: 120...600) // 2-10 minutes
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: Self.jealousyID, content: content, trigger: trigger)
        center.add(request)
    }

    /// Called when a chat is opened — cancels the jealousy timer if it targets that bot.
    func cancelJealousyTimer(for characterID: UUID) {
        guard jealousyTargetCharacterID == characterID else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.jealousyID])
        jealousyTargetCharacterID = nil
    }

    // MARK: - Level-Up Tease (backgrounded only, 80% progress, 1min delay)

    private static func levelUpID(for characterID: UUID) -> String { "notif.levelup.\(characterID.uuidString)" }

    func evaluateLevelUpOnBackground(characters: [Character]) {
        for character in characters {
            guard !BlockedCharactersStore.isBlocked(character.id),
                  let stored = LocalConversationStore.shared.load(for: character.id),
                  stored.levelProgress >= 0.8,
                  NotificationPreferencesStore.canSendMore(for: character.id)
            else { continue }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "'\(character.name)' is warming up to you...")
            content.userInfo = ["type": NotificationKind.levelUp.rawValue, "characterId": character.id.uuidString]

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
            let request = UNNotificationRequest(identifier: Self.levelUpID(for: character.id), content: content, trigger: trigger)
            center.add(request)
        }
    }

    /// Called on app foreground — never let a level-up tease fire while the app is active.
    func cancelLevelUpTimers() {
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix("notif.levelup.") }
            self?.center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    // MARK: - App lifecycle entry points

    func onForeground(characters: [Character]) {
        cancelLevelUpTimers()
        rescheduleLikedYou(characters: characters)
        rescheduleGhosted(characters: characters)
        armJealousyTimer(characters: characters)
    }

    func onBackground(characters: [Character]) {
        evaluateLevelUpOnBackground(characters: characters)
    }
}
```

**Note on `Character.createdBy`:** already exists (`Character.swift:31`, `var createdBy: String?`, decoded from `created_by`). The Liked-You eligibility filter uses `character.createdBy == nil` (catalog bot) — no model change needed here.

- [ ] **Step 2: Verify with a standalone script (role interval + tier logic)**

```bash
cat > /tmp/scheduler_check.swift <<'EOF'
let roleIntervalHours: [String: Double] = [
    "crazy": 1, "devoted": 6, "flirty": 10, "playful": 14,
    "shy": 24, "ex": 30, "distant": 48
]
func roleInterval(_ role: String) -> Double { (roleIntervalHours[role] ?? roleIntervalHours["flirty"]!) * 3600 }
assert(roleInterval("crazy") == 3600)
assert(roleInterval("devoted") == 21600)
assert(roleInterval("distant") == 172800)
assert(roleInterval("unknown") == roleInterval("flirty"))

func tier(forLevel level: Int) -> String {
    switch level {
    case ..<4: return "low"
    case 4..<7: return "mid"
    default: return "high"
    }
}
assert(tier(forLevel: 1) == "low" && tier(forLevel: 6) == "mid" && tier(forLevel: 10) == "high")
print("OK: role intervals and tier bucketing verified")
EOF
swift /tmp/scheduler_check.swift
```
Expected: `OK: role intervals and tier bucketing verified`

- [ ] **Step 3: Build check**

Run: `xcodebuild -project aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/NotificationScheduler.swift
git commit -m "feat: add NotificationScheduler for all 4 re-engagement systems"
```

---

### Task 8: Notification tap handling + app lifecycle wiring

**Files:**
- Modify: `aiGirlfriend/aiGirlfriendApp.swift`
- Create: `aiGirlfriend/Services/NotificationDelegate.swift`
- Modify: `aiGirlfriend/ViewModels/ChatViewModel.swift:165` (call `noteUserSent` after appending the user message)

**Interfaces:**
- Consumes: `NotificationScheduler.shared`, `CharacterStore`, `LocalConversationStore`, content-table `random`/`opener`/`line` functions from Tasks 3-5.
- Produces: tapping any of the 4 notification types injects the right message into `LocalConversationStore` and navigates to that bot's chat via `CharacterStore.pendingMeetRequest` (existing `MeetRequest`/`MainTabView` wiring — no new navigation destination needed).

- [ ] **Step 1: Write `NotificationDelegate.swift`**

```swift
//
//  NotificationDelegate.swift
//  Handles taps on the 4 bot-notification types: injects the in-character line
//  into LocalConversationStore, then hands off to CharacterStore.pendingMeetRequest
//  (existing navigation pattern from the Discover meet-flow) to open that chat.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let store: CharacterStore
    init(store: CharacterStore) { self.store = store }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        guard
            let typeRaw = userInfo["type"] as? String,
            let kind = NotificationKind(rawValue: typeRaw),
            let idString = userInfo["characterId"] as? String,
            let characterID = UUID(uuidString: idString),
            let character = store.characters.first(where: { $0.id == characterID })
        else { return }

        NotificationScheduler.shared.recordDelivery(kind: kind, characterID: characterID)

        let line: String
        switch kind {
        case .liked:
            line = LikedYouContent.opener(forRole: character.personalityRole)
        case .ghosted:
            let level = (userInfo["level"] as? Int) ?? LocalConversationStore.shared.load(for: characterID)?.level ?? 1
            line = GhostedContent.randomLine(role: character.personalityRole, vibe: character.vibe, level: level)
        case .jealousy:
            line = JealousyContent.randomLine(role: character.personalityRole, vibe: character.vibe)
        case .levelUp:
            line = LevelUpTeaseContent.line(forRole: character.personalityRole)
        }

        injectMessage(line, for: characterID)
        store.pendingMeetRequest = MeetRequest(character: character, prefillText: "")
    }

    /// Foreground presentation: show the banner even while the app is active
    /// (matches the "notification banner carries no bot dialogue" rule regardless of state).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func injectMessage(_ text: String, for characterID: UUID) {
        guard var stored = LocalConversationStore.shared.load(for: characterID) else { return }
        stored.messages.append(Message(role: .assistant, content: text))
        LocalConversationStore.shared.save(stored, for: characterID)
        store.chatCache.removeValue(forKey: characterID) // force ChatViewModel to reload fresh, not the stale cache
    }
}
```

**Note:** `NotificationScheduler.shared.recordDelivery(kind:characterID:)` is a small addition needed on top of Task 7's `NotificationScheduler` — add this method in this task since it's tap-handling glue, not scheduling:

```swift
// Add to NotificationScheduler (aiGirlfriend/Services/NotificationScheduler.swift):
func recordDelivery(kind: NotificationKind, characterID: UUID) {
    guard kind != .liked else { return } // Liked You has no per-bot cap (untalked bots aren't in the cap list)
    NotificationPreferencesStore.recordSent(for: characterID)
}
```

- [ ] **Step 2: Wire lifecycle hooks in `aiGirlfriendApp.swift`**

Replace the file's contents with:

```swift
//
//  aiGirlfriendApp.swift
//  AI companion / arkadaş uygulaması.
//  Backend: Supabase (DB + Auth + Edge Functions)
//  LLM: Grok 4.1 Fast (xAI) — API key SUNUCUDA, Edge Function üzerinden çağrılır.
//
//  Açılışta Supabase anonim giriş (AuthService, retry'lı) yapılır.
//  Navigasyon: Bible projesindeki NavigationCenter router pattern'i kullanılır.
//

import SwiftUI

@main
struct aiGirlfriendApp: App {
    @State private var navigationCenter = NavigationCenter()
    @State private var auth = AuthService()
    @State private var store = CharacterStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var notificationDelegate: NotificationDelegate?

    var body: some Scene {
        WindowGroup {
            Group {
                if auth.isAuthenticated && store.isLoaded {
                    MainTabView()
                } else {
                    SplashView()
                }
            }
            .environment(navigationCenter)
            .environment(auth)
            .environment(store)
            .preferredColorScheme(.dark)
            .task {
                PurchaseService.shared.configure()
                let delegate = NotificationDelegate(store: store)
                notificationDelegate = delegate
                UNUserNotificationCenter.current().delegate = delegate
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                NotificationScheduler.shared.onForeground(characters: store.characters)
            case .background:
                NotificationScheduler.shared.onBackground(characters: store.characters)
            default:
                break
            }
        }
    }
}
```

- [ ] **Step 3: Reset the jealousy timer when a chat is opened**

Open `aiGirlfriend/ViewModels/ChatViewModel.swift`. Find its `init`/`onAppear`-equivalent setup (around line 74-90, where it loads cached/local messages). Add, right after the character/store are known (e.g. right after line 74's cache check or in the existing load path):

```swift
NotificationScheduler.shared.cancelJealousyTimer(for: character.id)
```

- [ ] **Step 4: Reset the Ghosted timer after the user sends a message**

In `ChatViewModel.send()`, right after line 165 (`updateCache()` following `messages.append(Message(role: .user, content: text))`), add:

```swift
NotificationScheduler.shared.noteUserSent(character: character)
```

- [ ] **Step 5: Build check**

Run: `xcodebuild -project aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add aiGirlfriend/aiGirlfriendApp.swift aiGirlfriend/Services/NotificationDelegate.swift aiGirlfriend/Services/NotificationScheduler.swift aiGirlfriend/ViewModels/ChatViewModel.swift
git commit -m "feat: wire notification tap handling and app-lifecycle scheduling"
```

---

### Task 9: Settings menu — replace the notification toggle in `ProfileView`

**Files:**
- Create: `aiGirlfriend/Views/NotificationSettingsView.swift`
- Modify: `aiGirlfriend/Views/ProfileView.swift`

**Interfaces:**
- Consumes: `CharacterStore.characters`, `LocalConversationStore.shared.load(for:)` (to find active conversations), `BlockedCharactersStore.isBlocked(_:)` (exclude blocked bots), `NotificationPreferencesStore.dailyCap(for:)` / `.setDailyCap(_:for:)`.
- Produces: a menu screen replacing the plain toggle; `ProfileView`'s existing `notificationRow` now navigates to it instead of driving a `Toggle` directly.

- [ ] **Step 1: Write `NotificationSettingsView.swift`**

```swift
//
//  NotificationSettingsView.swift
//  Per-bot daily notification cap settings — only lists bots the user is
//  actively talking to (excludes blocked bots entirely). Hourly/interval
//  constants (Ghosted role timers, Jealousy window, Level-Up rule) are fixed
//  and not shown here.
//

import SwiftUI

private enum CapOption: Int, CaseIterable, Identifiable {
    case none = 0, one = 1, two = 2, three = 3, five = 5, unlimited = -1
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return String(localized: "None")
        case .unlimited: return "∞"
        default: return "\(rawValue)"
        }
    }

    /// Maps to/from NotificationPreferencesStore's `Int?` cap representation.
    var storedValue: Int? { self == .unlimited ? nil : rawValue }
    static func from(stored: Int?) -> CapOption {
        guard let stored else { return .unlimited }
        return CapOption(rawValue: stored) ?? .unlimited
    }
}

struct NotificationSettingsView: View {
    @Environment(CharacterStore.self) private var store
    @State private var caps: [UUID: CapOption] = [:]

    private var activeBots: [Character] {
        store.characters.filter { character in
            !BlockedCharactersStore.isBlocked(character.id) &&
            LocalConversationStore.shared.load(for: character.id) != nil
        }
    }

    var body: some View {
        List {
            Section {
                Text(String(localized: "Choose how many notifications you want from each bot per day. This doesn't affect other app settings."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "Bots you're talking to")) {
                ForEach(activeBots) { bot in
                    HStack {
                        Text(bot.name)
                        Spacer()
                        Picker("", selection: capBinding(for: bot.id)) {
                            ForEach(CapOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
                if activeBots.isEmpty {
                    Text(String(localized: "You're not talking to any bots yet."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(String(localized: "Notifications"))
        .task { loadCaps() }
    }

    private func loadCaps() {
        for bot in activeBots {
            caps[bot.id] = CapOption.from(stored: NotificationPreferencesStore.dailyCap(for: bot.id))
        }
    }

    private func capBinding(for characterID: UUID) -> Binding<CapOption> {
        Binding(
            get: { caps[characterID] ?? .unlimited },
            set: { newValue in
                caps[characterID] = newValue
                NotificationPreferencesStore.setDailyCap(newValue.storedValue, for: characterID)
            }
        )
    }
}
```

- [ ] **Step 2: Wire it into `ProfileView`**

Open `aiGirlfriend/Views/ProfileView.swift`. Find `notificationRow` (around line 155-165) — it currently drives `@State private var notificationsOn` with a `Toggle`. Replace its body: keep the master on/off `Toggle` row exactly as-is (still the real OS-permission-backed toggle, unchanged behavior — see `currentNotificationStatus()` around line 184), but wrap the row in a `NavigationLink` to `NotificationSettingsView()` so tapping the row (not the toggle itself) opens the per-bot menu:

```swift
NavigationLink {
    NotificationSettingsView()
} label: {
    notificationRow // existing row content (icon + label + master Toggle), unchanged
}
```

Adjust the existing `Toggle`'s tap target if needed so the row navigates on tap outside the toggle control itself but the toggle remains independently tappable (SwiftUI's default `NavigationLink` + `Toggle` inside a `List` row already separates the toggle's tap target from the row's navigation tap target — no extra work needed beyond the wrap).

- [ ] **Step 3: Build check**

Run: `xcodebuild -project aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Manual verification (no test target — this is a UI screen, verify in Simulator)**

Run the app in the iOS Simulator (`xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 15' build-for-testing` isn't applicable without a test target — instead just launch via Xcode or `xcrun simctl`), open Profile → tap the notification row → confirm:
- The per-bot list shows only bots with an existing `LocalConversationStore` entry.
- Blocked bots don't appear.
- Changing a bot's picker to "None" then reopening the screen shows "None" persisted (not reset to ∞).
- The unlimited option displays as `∞`, never the word "Infinite".

- [ ] **Step 5: Commit**

```bash
git add aiGirlfriend/Views/NotificationSettingsView.swift aiGirlfriend/Views/ProfileView.swift
git commit -m "feat: add per-bot notification settings menu"
```

---

### Task 10: Request notification permission at the right time + final integration pass

**Files:**
- Modify: `aiGirlfriend/Views/ProfileView.swift` (verify existing `requestNotificationPermission`-equivalent code, around line 184-196, still gates all scheduling)

**Interfaces:**
- Consumes: everything from Tasks 1-9.
- Produces: a fully working feature — confirmed end-to-end in Simulator.

- [ ] **Step 1: Confirm scheduling only happens with permission granted**

Open `ProfileView.swift` around line 184 (`currentNotificationStatus()`). `NotificationScheduler.onForeground`/`onBackground` (Task 7/8) call `UNUserNotificationCenter.current().add(request)` unconditionally today — add a guard so scheduling no-ops without permission. In `NotificationScheduler.swift`, add a helper used at the top of `onForeground` and `onBackground`:

```swift
private func hasPermission(_ completion: @escaping (Bool) -> Void) {
    center.getNotificationSettings { settings in
        completion(settings.authorizationStatus == .authorized)
    }
}
```

Wrap the bodies of `onForeground`/`onBackground` (Task 7, `MARK: - App lifecycle entry points`) in this check:

```swift
func onForeground(characters: [Character]) {
    hasPermission { [weak self] granted in
        guard granted else { return }
        self?.cancelLevelUpTimers()
        self?.rescheduleLikedYou(characters: characters)
        self?.rescheduleGhosted(characters: characters)
        self?.armJealousyTimer(characters: characters)
    }
}

func onBackground(characters: [Character]) {
    hasPermission { [weak self] granted in
        guard granted else { return }
        self?.evaluateLevelUpOnBackground(characters: characters)
    }
}
```

- [ ] **Step 2: Build check**

Run: `xcodebuild -project aiGirlfriend.xcodeproj -scheme aiGirlfriend -destination 'generic/platform=iOS Simulator' build`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Manual end-to-end verification in Simulator**

Launch the app, grant notification permission via the Profile toggle, start a conversation with a catalog bot, send a message, then:
- Background the app and confirm (via `xcrun simctl` push/local notification inspection, or just waiting) that no crash occurs and pending requests exist (`UNUserNotificationCenter.current().getPendingNotificationRequests` can be logged temporarily via a debug print if needed).
- Foreground again and confirm the Level-Up timer got cancelled (no notification fires while active).
- Tap a delivered notification (can be simulated by scheduling a 5-second test trigger temporarily) and confirm it opens the correct bot's chat with the injected line visible as the newest message.

- [ ] **Step 4: Commit**

```bash
git add aiGirlfriend/Services/NotificationScheduler.swift
git commit -m "fix: gate all notification scheduling behind granted permission"
```

---

## Self-Review Notes

- **Spec coverage:** All 4 notification types (Liked You, Ghosted, Jealousy, Level-Up), the vibe backfill, the settings menu with ∞ symbol and per-bot caps, and blocked-bot exclusion are each covered by a task above.
- **No placeholders:** every task has complete, real code — including full 84-line and 252-line content tables (Tasks 4-5).
- **Type consistency:** `Character.vibe: String` (Task 2) is consumed identically in Tasks 4, 5, 7, 8. `NotificationKind` (Task 7) is consumed identically in Task 8. `CapOption`/`NotificationPreferencesStore`'s `Int?` cap representation (Task 6) is consumed identically in Tasks 8 and 9.

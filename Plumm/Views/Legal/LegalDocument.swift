//
//  LegalDocument.swift
//  Gizlilik Politikası + Kullanım Koşulları METNİ (tek kaynak) ve basit bir
//  blok modeli. Ekran/render tarafı: LegalDocumentView.
//
//  ⚠️ AYNI METİN barındırılan HTML kopyalarda da duruyor:
//     docs/legal/privacy.html ve docs/legal/terms.html
//  App Store Connect "Privacy Policy URL" / "EULA" alanları bir WEB adresi
//  istediği için iki kopya var — birini güncelleyen DİĞERİNİ de güncellemeli.
//
//  Metin İngilizce: App Review'ın okuduğu dil + uygulamanın varsayılan dili.
//  İşletmeci/adres/yargı yeri alanları DOLU (Miles Warner, Kadıköy/İstanbul,
//  Türkiye hukuku) — değişirse HTML kopyalarla birlikte güncellenmeli.
//

import Foundation

/// Bir hukuki metnin gövde bloğu — düz paragraf veya madde listesi.
enum LegalBlock: Identifiable {
    case p(String)
    case bullets([String])

    var id: String {
        switch self {
        case .p(let text): return "p:\(text.prefix(40))"
        case .bullets(let items): return "b:\(items.first?.prefix(40) ?? "")"
        }
    }
}

struct LegalSection: Identifiable {
    let heading: String
    let blocks: [LegalBlock]
    var id: String { heading }
}

struct LegalDocument: Identifiable {
    /// `.sheet(item:)` ile açılabilmesi için — başlık zaten tekil.
    var id: String { title }
    let title: String
    let updated: String
    let intro: String
    let sections: [LegalSection]
}

// MARK: - Gizlilik Politikası

extension LegalDocument {
    static let effectiveDate = "26 July 2026"

    static let privacy = LegalDocument(
        title: "Privacy Policy",
        updated: effectiveDate,
        intro: """
        Plumm is built privacy-first. You do not create an account, you never tell us your \
        name, email address or phone number, and we do not track you. This policy explains \
        exactly what the app keeps, where it is kept, and who can reach it.
        """,
        sections: [
            LegalSection(heading: "The short version", blocks: [
                .bullets([
                    "No sign-up. No email, no phone number, no password, no social login. Your session is an anonymous ID.",
                    "No advertising, no ad SDKs, no IDFA/ATT tracking prompt, no third-party analytics — the app ships without them.",
                    "We never sell, rent or share your data with data brokers or advertisers. Ever.",
                    "Your chats live in a database protected by Supabase Row Level Security (RLS): each row is bound to your own anonymous ID, and no other user can read it.",
                    "Some things never leave your phone at all — the first name you type during onboarding and any photo you save into a chat.",
                    "You can delete a conversation from inside the app, and it is deleted on the server too.",
                ]),
            ]),
            LegalSection(heading: "Who we are", blocks: [
                .p("""
                Plumm (the “App”) is operated by Miles Warner, Bağdat Caddesi No: 142, Apt. 5, 34710 Kadıköy, İstanbul, Türkiye \
                (“we”, “us”). For any privacy question or request you can reach us at \
                plumappx@protonmail.com.
                """),
            ]),
            LegalSection(heading: "No account, no identity", blocks: [
                .p("""
                When you first open Plumm, the app signs in anonymously with Supabase Auth. \
                That produces a random user ID (a UUID) and a session token. That ID is the \
                only identifier we hold: it is not linked to your name, your email, your \
                phone number, your Apple ID or your contacts, and we have no way to work \
                backwards from it to your real-world identity.
                """),
                .p("""
                Because there is no login, your data is tied to that anonymous session on \
                this device. If you delete the app or reset the device, the session can no \
                longer be recovered — and neither can the chats attached to it.
                """),
            ]),
            LegalSection(heading: "What is stored on our servers", blocks: [
                .p("""
                Our backend runs on Supabase (Postgres database, authentication, storage and \
                Edge Functions). Stored against your anonymous ID:
                """),
                .bullets([
                    "Your conversations and messages — so a chat is still there when you reopen the app or reinstall while the session is alive.",
                    "Relationship progress — level and progress within a level for each character.",
                    "Coin balance, and the subscription tier reported by the store.",
                    "Characters you create with the character builder, and the AI-generated photos and voice clips produced for you.",
                    "Basic technical records needed to run the service, such as server-side error logs and rate-limit counters.",
                ]),
                .p("""
                We do not store your device's contacts, photo library, location, health data, \
                calendar or advertising identifier. The App does not ask for those permissions.
                """),
            ]),
            LegalSection(heading: "What never leaves your device", blocks: [
                .bullets([
                    "The first name you enter during onboarding — it is saved in local app storage only and is never uploaded.",
                    "Photos you send into a chat — they are written to the app's private folder on the device. They are not uploaded to our storage.",
                    "Downloaded voice clips and cached images, kept locally so the app is fast and uses less data.",
                    "Your notification schedule — reminders are created and fired locally by iOS (see “Notifications” below).",
                ]),
                .p("""
                One clarification, because it matters: a photo you send stays on your device, \
                but in order for the character to be able to react to it, a copy is transmitted \
                to the AI provider that generates the reply. It is used for that reply and is \
                not stored by us. If you do not want an image processed that way, do not send it.
                """),
            ]),
            LegalSection(heading: "How Row Level Security protects your chats", blocks: [
                .p("""
                Row Level Security (RLS) is a Postgres feature that filters data at the \
                database level, per row, before any result is returned. Every table that holds \
                user data in Plumm has RLS enabled with policies that compare the requesting \
                session's ID to the owner of the row (auth.uid() = user_id).
                """),
                .bullets([
                    "The App only ever talks to the database with the public key plus your own session token. Under RLS that combination can read and write your rows and nothing else.",
                    "Another user — or anyone holding the public key, which is designed to be public — cannot read, modify or delete your conversations. The database refuses to return the rows.",
                    "Tables that only the server needs have RLS enabled with no client policy at all, so the App cannot touch them.",
                    "Privileged keys (service role) and every third-party API key live exclusively in server-side Edge Functions. They are never shipped inside the App and cannot be extracted from it.",
                ]),
                .p("""
                To be straight with you about the limits of that guarantee: our Edge Functions \
                run with a privileged role so they can do their job — saving a message, charging \
                a coin, generating a photo — and Supabase, as our hosting provider, operates the \
                infrastructure the data sits on. Access on our side is limited to what is needed \
                to run and support the service (for example, investigating a bug or a safety \
                report). We do not read conversations for curiosity, profiling, advertising or \
                training our own models.
                """),
            ]),
            LegalSection(heading: "AI processing and service providers", blocks: [
                .p("""
                Plumm's characters are generated by third-party AI services. To produce a \
                reply, the relevant part of the conversation (and, where applicable, an image \
                you sent or a text prompt) is transmitted to the provider through our servers:
                """),
                .bullets([
                    "xAI (Grok) — chat replies.",
                    "OpenAI — supporting text and moderation-related tasks.",
                    "Civitai — image generation.",
                    "ElevenLabs — voice message synthesis.",
                    "Supabase — database, authentication, storage and Edge Functions hosting.",
                    "RevenueCat — subscription and purchase state (receipt validation), together with Apple.",
                ]),
                .p("""
                These providers act as processors for us and are bound by their own terms; \
                they are not permitted to use your content for advertising. Requests are sent \
                with your anonymous ID at most — never with a name, an email address or a \
                payment detail, because we do not have them.
                """),
            ]),
            LegalSection(heading: "Purchases", blocks: [
                .p("""
                Subscriptions and coin packs are sold through Apple's In-App Purchase. Payment \
                is handled entirely by Apple: we never see or receive your card number, billing \
                address or Apple ID. We receive a validated entitlement (“this anonymous ID has \
                an active plan”) via RevenueCat and Apple's receipt, and we store the resulting \
                tier and coin balance.
                """),
            ]),
            LegalSection(heading: "Notifications", blocks: [
                .p("""
                Reminders and character messages are scheduled as local notifications by iOS on \
                your device. The App does not register for remote push notifications, so there \
                is no device push token, and we do not use a third-party push provider. \
                Notifications can be turned off at any time in the Profile tab or in iOS Settings.
                """),
            ]),
            LegalSection(heading: "No tracking and no advertising", blocks: [
                .p("""
                The App contains no advertising SDK, no attribution SDK and no third-party \
                analytics SDK. We do not use the advertising identifier (IDFA), we do not \
                fingerprint your device, and we do not build profiles about you or sell \
                audiences. Apple may provide us with aggregate, non-identifying App Store \
                statistics (downloads, crashes) which we cannot tie to an individual user.
                """),
            ]),
            LegalSection(heading: "Adults only", blocks: [
                .p("""
                Plumm is intended solely for users aged 18 and over. It is not directed at \
                children and we do not knowingly collect data from anyone under 18. If we learn \
                that an underage person is using the App, we will terminate the session and \
                delete the associated data.
                """),
            ]),
            LegalSection(heading: "Retention and deletion", blocks: [
                .bullets([
                    "Deleting a conversation in the App deletes it on the server, not just on the screen.",
                    "Deleting the App removes everything held locally on the device (your onboarding name, saved photos, cached media) and ends your access to the anonymous session.",
                    "You can ask us to erase all server-side data attached to your anonymous ID by emailing plumappx@protonmail.com with that ID (Profile tab → tap the ID to copy it). We will action it without undue delay and in any case within 30 days.",
                    "Records we are legally required to keep (for example, purchase records for tax purposes) are retained for the period the law requires.",
                ]),
            ]),
            LegalSection(heading: "Your rights", blocks: [
                .p("""
                Depending on where you live, you may have the right to access, correct, export \
                or delete your data, to object to or restrict processing, and to complain to \
                your data protection authority. Because the App is anonymous, we can only act \
                on such a request if you send us the anonymous ID shown in the Profile tab — it \
                is the only way we can locate your data. Requests go to plumappx@protonmail.com.
                """),
            ]),
            LegalSection(heading: "International transfers", blocks: [
                .p("""
                Our provider infrastructure and the AI services listed above may process data \
                in countries outside your own, including the United States. Where required, \
                such transfers rely on the safeguards offered by those providers, such as the \
                European Commission's Standard Contractual Clauses.
                """),
            ]),
            LegalSection(heading: "Security", blocks: [
                .p("""
                Traffic between the App and our servers is encrypted in transit (TLS). Data at \
                rest is encrypted by our hosting provider. Access to our systems is restricted \
                and secrets are held server-side only. No system is perfectly secure, so we \
                cannot promise absolute security — but we do commit to notifying affected users \
                and the competent authority where a breach requires it.
                """),
            ]),
            LegalSection(heading: "Changes to this policy", blocks: [
                .p("""
                If we change this policy we will update the date at the top and, for material \
                changes, tell you inside the App. Continuing to use Plumm after a change means \
                you accept the updated policy.
                """),
            ]),
            LegalSection(heading: "Contact", blocks: [
                .p("Questions, requests or complaints: plumappx@protonmail.com"),
            ]),
        ]
    )
}

// MARK: - Kullanım Koşulları (EULA)

extension LegalDocument {
    static let terms = LegalDocument(
        title: "Terms of Use",
        updated: effectiveDate,
        intro: """
        These Terms of Use are the agreement between you and Miles Warner for the \
        Plumm application. Please read them: by installing or using Plumm you accept them in \
        full. If you do not accept them, do not use the App.
        """,
        sections: [
            LegalSection(heading: "1. You must be 18 or older", blocks: [
                .p("""
                Plumm is an adult entertainment application. You confirm that you are at least \
                18 years old (or older, where your local law sets a higher age of majority) and \
                that using the App is lawful where you are. We may end your access if we \
                believe this is not the case.
                """),
            ]),
            LegalSection(heading: "2. What Plumm is — and is not", blocks: [
                .p("""
                Plumm provides fictional AI companions. Characters, their photos, their voices, \
                their memories and everything they say are generated by artificial intelligence. \
                They are not real people, they are not human operators, and any resemblance to a \
                real person is unintended.
                """),
                .p("""
                Content generated by AI can be inaccurate, inconsistent or inappropriate. \
                Nothing in the App is professional advice — it is not medical, psychological, \
                legal or financial advice, and it is not a crisis or therapy service. If you are \
                in distress or in danger, contact a qualified professional or your local \
                emergency number.
                """),
            ]),
            LegalSection(heading: "3. Your session", blocks: [
                .p("""
                Access is granted through an anonymous session created on your device; there is \
                no username or password to recover. You are responsible for the device that \
                holds the session. If you delete the App, lose the device or reset it, the \
                session — and the conversations, coins and entitlements attached to it — cannot \
                be restored by us.
                """),
            ]),
            LegalSection(heading: "4. Acceptable use", blocks: [
                .p("You agree not to use Plumm to:"),
                .bullets([
                    "create, request or attempt to generate any sexual content involving minors, or content that presents any character as a minor;",
                    "depict, request or promote non-consensual acts, sexual violence, bestiality, incest, or other content prohibited by law or by our providers' policies;",
                    "impersonate a real, identifiable person, or upload another person's likeness or private images without their consent;",
                    "harass, threaten, defame or stalk any person, or send us content that is unlawful;",
                    "circumvent, disable or attempt to bypass safety filters, moderation, rate limits, the coin system or any paid gate (including via prompt injection or “jailbreak” prompts);",
                    "reverse engineer, decompile, scrape, resell, sublicense or automate access to the App or our APIs, or extract credentials or model outputs at scale;",
                    "upload malware or otherwise interfere with the operation, integrity or security of the service.",
                ]),
                .p("""
                We may moderate, refuse, remove or restrict content, and we may suspend or \
                terminate your access, where we reasonably believe these rules have been broken \
                or where the law requires it.
                """),
            ]),
            LegalSection(heading: "5. Your content and AI output", blocks: [
                .p("""
                You keep the rights you already have in the text and images you provide. You \
                grant us a limited, worldwide, royalty-free licence to host, transmit and \
                process that content strictly for the purpose of operating the App for you — \
                including sending it to the AI providers that generate a reply. You confirm you \
                have the rights to any content you submit.
                """),
                .p("""
                Output generated for you may be used by you for your personal, non-commercial \
                enjoyment. AI output is not unique: similar or identical output may be generated \
                for other users, so we cannot grant you exclusive rights to it.
                """),
            ]),
            LegalSection(heading: "6. Coins, subscriptions and billing", blocks: [
                .bullets([
                    "Coins are a limited, personal, non-transferable licence to use paid features inside the App. They are not money, not a deposit, not a stored-value instrument, have no cash value, and cannot be redeemed, exchanged or transferred outside the App.",
                    "Prices, coin balances and the coin cost of a feature (for example creating a character, requesting a photo or a voice message) are shown in the App and may change over time; the price shown at the moment of purchase applies.",
                    "Coins expire and are lost if your session ends, if the data attached to it is deleted, or if the App is discontinued.",
                    "Subscriptions are auto-renewable and are billed by Apple to your Apple ID. They renew for the same period unless auto-renew is turned off at least 24 hours before the end of the current period. Manage or cancel a subscription in App Store → Apple ID → Subscriptions; deleting the App does not cancel a subscription.",
                    "All purchases are processed by Apple. Purchases are final except where a refund is required by law or granted by Apple. Refund requests must be made to Apple, not to us, since we do not process payments.",
                    "Where a free trial or introductory offer is granted, any unused portion is forfeited if you buy a subscription during that period, as required by Apple's rules.",
                ]),
            ]),
            LegalSection(heading: "7. Availability and changes", blocks: [
                .p("""
                We may add, change, suspend or discontinue features at any time, and we may \
                limit usage to protect the service (for example rate limits or fair-use caps). \
                The App depends on third-party AI providers; if a provider is unavailable, part \
                of the App may not work. We do not promise uninterrupted or error-free service.
                """),
            ]),
            LegalSection(heading: "8. Privacy", blocks: [
                .p("""
                Our handling of data is described in the Privacy Policy, which forms part of \
                these Terms. In short: no account, no advertising, no third-party analytics, and \
                your conversations are protected at the database level by Row Level Security.
                """),
            ]),
            LegalSection(heading: "9. Intellectual property", blocks: [
                .p("""
                The App, its name, design, code and assets are owned by us or our licensors and \
                are protected by intellectual property law. You receive a personal, revocable, \
                non-exclusive, non-transferable licence to use the App for its intended purpose. \
                All rights not expressly granted are reserved.
                """),
            ]),
            LegalSection(heading: "10. Disclaimers", blocks: [
                .p("""
                To the fullest extent permitted by law, the App is provided “as is” and “as \
                available”, without warranties of any kind, whether express or implied, \
                including merchantability, fitness for a particular purpose, accuracy or \
                non-infringement. We do not warrant that AI-generated content will be accurate, \
                appropriate, or suited to your expectations. Nothing here excludes rights you \
                have as a consumer that cannot be excluded by law.
                """),
            ]),
            LegalSection(heading: "11. Limitation of liability", blocks: [
                .p("""
                To the fullest extent permitted by law, we are not liable for indirect, \
                incidental, special, consequential or punitive damages, nor for lost data, lost \
                profits or emotional distress arising from your use of the App. Our total \
                liability for any claim is limited to the greater of the amount you paid us in \
                the twelve months before the claim, or USD 50. Some jurisdictions do not allow \
                these limitations, in which case they apply only to the extent permitted.
                """),
            ]),
            LegalSection(heading: "12. Indemnity", blocks: [
                .p("""
                You agree to indemnify and hold us harmless from claims, damages and costs \
                (including reasonable legal fees) arising from content you submit or from your \
                use of the App in breach of these Terms or of applicable law.
                """),
            ]),
            LegalSection(heading: "13. Termination", blocks: [
                .p("""
                You may stop using the App at any time by deleting it. We may suspend or \
                terminate your access if you breach these Terms, if required by law, or if we \
                discontinue the service. On termination, sections that by their nature should \
                survive (ownership, disclaimers, liability, indemnity, governing law) continue \
                to apply.
                """),
            ]),
            LegalSection(heading: "14. Apple-specific terms", blocks: [
                .bullets([
                    "These Terms are between you and us only, not with Apple. Apple is not responsible for the App or its content.",
                    "The App is licensed, not sold, to you for use only on Apple-branded devices, subject to the Usage Rules of the Apple Media Services Terms and Conditions.",
                    "Apple has no obligation to provide maintenance or support for the App.",
                    "If the App fails to conform to any applicable warranty, you may notify Apple, and Apple may refund the purchase price; to the maximum extent permitted by law, Apple has no other warranty obligation with respect to the App.",
                    "Apple is not responsible for addressing any claim by you or a third party relating to the App, including product liability, legal or regulatory non-compliance, or consumer protection claims.",
                    "In the event of a third-party claim that the App infringes intellectual property rights, we, not Apple, are responsible for the investigation, defence, settlement and discharge of that claim.",
                    "You represent that you are not located in a country subject to a U.S. Government embargo or designated as a “terrorist supporting” country, and that you are not on any U.S. Government list of prohibited or restricted parties.",
                    "Apple and its subsidiaries are third-party beneficiaries of these Terms and may enforce them against you.",
                ]),
            ]),
            LegalSection(heading: "15. Governing law", blocks: [
                .p("""
                These Terms are governed by the laws of the Republic of Türkiye, without regard to \
                conflict-of-law rules, and the courts of Istanbul (Anadolu), Türkiye have jurisdiction — except \
                where mandatory consumer protection law in your country of residence gives you \
                the right to bring proceedings locally.
                """),
            ]),
            LegalSection(heading: "16. Contact", blocks: [
                .p("Miles Warner, Bağdat Caddesi No: 142, Apt. 5, 34710 Kadıköy, İstanbul, Türkiye — plumappx@protonmail.com"),
            ]),
        ]
    )
}

//
//  CreateCharacterView.swift
//  Karakter yaratma sihirbazı — kullanıcı isim yazar, kişilik/kategori/vibe/
//  meslek/yaş + görünüm (saç/göz/burun/ten) özelliklerini seçer; AI bu
//  özelliklere göre bir fotoğraf + bio + system_prompt üretir.
//

import SwiftUI
import UIKit

// MARK: - Role definitions

private struct RoleOption: Identifiable {
    let id: String          // DB value
    let emoji: String
    let label: String
    let description: String
}

private let roleOptions: [RoleOption] = [
    .init(id: "flirty",  emoji: "💋", label: String(localized: "Flirty"),
          description: String(localized: "Forward & charming from day one")),
    .init(id: "distant", emoji: "❄️", label: String(localized: "Distant"),
          description: String(localized: "Cold at first, slow to open up")),
    .init(id: "shy",     emoji: "🌸", label: String(localized: "Shy"),
          description: String(localized: "Nervous & sweet, gains confidence")),
    .init(id: "playful", emoji: "😏", label: String(localized: "Playful"),
          description: String(localized: "Witty banter, jokes & teasing")),
    .init(id: "devoted", emoji: "🥰", label: String(localized: "Devoted"),
          description: String(localized: "Deep attachment from the start")),
    .init(id: "crazy",   emoji: "🔥", label: String(localized: "Crazy"),
          description: String(localized: "Intense love, always overthinking")),
    .init(id: "ex",      emoji: "💔", label: String(localized: "The Ex"),
          description: String(localized: "Acts like she's moved on… hasn't")),
]

// MARK: - Personality definitions (role + vibe merged into one pick)
//
// "Select Mood" step used to be two separate steps (role, then vibe) — the
// role step was never actually wired into the wizard (dead `roleStep` var,
// `selectedRole` silently stayed at its "flirty" default). Merging them into
// one curated set fixes that gap and drops incoherent role/vibe pairings
// (e.g. Distant+Energetic). `role`/`vibe` still map 1:1 to the existing
// `personality_role`/`builder_selections.vibe` fields — no backend change.
// `crazy`/`ex` keep their existing single-role behavior (no vibe pairing,
// same as before), just borrowing one of the 4 existing vibe photos below
// so their card isn't blank.
private struct PersonalityOption: Identifiable {
    let id: String
    let role: String    // → personality_role
    let vibe: String    // → builder_selections.vibe / BuilderImages "vibe" key
    let label: String
    let description: String
}

private let personalityOptions: [PersonalityOption] = [
    .init(id: "flirty_energetic", role: "flirty", vibe: "Energetic",
          label: String(localized: "Firecracker"),
          description: String(localized: "Bubbly and forward, always chasing you")),
    .init(id: "flirty_elegant", role: "flirty", vibe: "Elegant",
          label: String(localized: "Charmer"),
          description: String(localized: "Smooth, confident, effortlessly seductive")),
    .init(id: "distant_mysterious", role: "distant", vibe: "Mysterious",
          label: String(localized: "Enigma"),
          description: String(localized: "Aloof and guarded, impossible not to chase")),
    .init(id: "distant_elegant", role: "distant", vibe: "Elegant",
          label: String(localized: "Ice Queen"),
          description: String(localized: "Cold and refined, hard to impress")),
    .init(id: "shy_sweet", role: "shy", vibe: "Sweet",
          label: String(localized: "Shy Sweetheart"),
          description: String(localized: "Nervous and sweet, opens up slowly")),
    .init(id: "shy_mysterious", role: "shy", vibe: "Mysterious",
          label: String(localized: "Quiet Mystery"),
          description: String(localized: "Reserved outside, secretly deep")),
    .init(id: "playful_energetic", role: "playful", vibe: "Energetic",
          label: String(localized: "Livewire"),
          description: String(localized: "Loud, witty, chaotic energy")),
    .init(id: "playful_mysterious", role: "playful", vibe: "Mysterious",
          label: String(localized: "Trickster"),
          description: String(localized: "Teasing jokes, keeps you guessing")),
    .init(id: "devoted_sweet", role: "devoted", vibe: "Sweet",
          label: String(localized: "Devoted Sweetheart"),
          description: String(localized: "Warm and attached from day one")),
    .init(id: "devoted_energetic", role: "devoted", vibe: "Energetic",
          label: String(localized: "Adoring"),
          description: String(localized: "Enthusiastic, always excited for you")),
    .init(id: "crazy", role: "crazy", vibe: "Energetic",
          label: String(localized: "Crazy"),
          description: String(localized: "Intense love, always overthinking")),
    .init(id: "ex", role: "ex", vibe: "Mysterious",
          label: String(localized: "The Ex"),
          description: String(localized: "Acts like she's moved on… hasn't")),
]

// MARK: - Profession definitions

private struct ProfessionOption: Identifiable {
    let id: String   // DB value — sent to server as-is, always English
    let emoji: String
    let label: String // localized display text
}

private let professionOptions: [ProfessionOption] = [
    .init(id: "Student",      emoji: "🎓", label: String(localized: "Student")),
    .init(id: "Artist",       emoji: "🎨", label: String(localized: "Artist")),
    .init(id: "Warrior",      emoji: "⚔️", label: String(localized: "Warrior")),
    .init(id: "Scientist",    emoji: "🔬", label: String(localized: "Scientist")),
    .init(id: "Musician",     emoji: "🎸", label: String(localized: "Musician")),
    .init(id: "Doctor",       emoji: "🩺", label: String(localized: "Doctor")),
    .init(id: "Chef",         emoji: "👩‍🍳", label: String(localized: "Chef")),
    .init(id: "Photographer", emoji: "📸", label: String(localized: "Photographer")),
    .init(id: "Model",        emoji: "💃", label: String(localized: "Model")),
    .init(id: "Writer",       emoji: "✍️", label: String(localized: "Writer")),
    .init(id: "Athlete",      emoji: "🏃‍♀️", label: String(localized: "Athlete")),
    .init(id: "Gamer",        emoji: "🎮", label: String(localized: "Gamer")),
]

// MARK: - View

struct CreateCharacterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CharacterStore.self) private var store

    // ── Step state ──
    @State private var stepIndex = 0
    @State private var phase: Phase = .steps

    // ── Selections ──
    @State private var characterName = ""
    // Tüm adımlar varsayılan olarak ilk seçenek seçili gelir.
    @State private var selectedRole = "flirty"
    @State private var selectedCategory = "Realistic"
    @State private var selectedVibe = "Energetic"
    @State private var selectedProfession = "Student"
    @State private var selectedAgeRange = AppearanceOptions.ageRanges[0]
    @State private var selectedHairstyle = AppearanceOptions.hairstyles[0]
    @State private var selectedHairColor = AppearanceOptions.hairColors[0]
    @State private var selectedEyeShape = AppearanceOptions.eyeShapes[0]
    @State private var selectedEyeColor = AppearanceOptions.eyeColors[0]
    @State private var selectedNoseShape = AppearanceOptions.noseShapes[0]
    @State private var selectedSkinTone = AppearanceOptions.skinTones[0]
    @State private var selectedBodyType = AppearanceOptions.bodyTypes[0]
    @State private var selectedEthnicity = AppearanceOptions.ethnicities[0]
    @State private var exHistory = ""
    @State private var selectedInterests: Set<String> = [CreateCharacterView.hobbies[0]]

    /// İlgi alanları / hobiler (50 seçenek, çoklu seçim).
    static let hobbies: [String] = [
        "🎵 Müzik", "🎬 Sinema", "✈️ Seyahat", "⚽ Spor", "🧘 Yoga",
        "💃 Dans", "🍳 Yemek", "📷 Fotoğraf", "🎨 Resim", "📚 Kitap",
        "🎮 Oyun", "✨ Anime", "🥾 Doğa yürüyüşü", "🏕️ Kamp", "🏊 Yüzme",
        "🏃 Koşu", "🏋️ Fitness", "🚴 Bisiklet", "⛷️ Kayak", "🏄 Sörf",
        "☕ Kahve", "🍷 Şarap", "🍸 Kokteyl", "👗 Moda", "💄 Makyaj",
        "🛍️ Alışveriş", "🖋️ Dövme", "🔮 Astroloji", "🧘‍♀️ Meditasyon", "🌱 Bahçıvanlık",
        "🐱 Kediler", "🐶 Köpekler", "🚗 Arabalar", "🏍️ Motosiklet", "💻 Teknoloji",
        "👩‍💻 Kodlama", "🎙️ Podcast", "😂 Stand-up", "🎭 Tiyatro", "🎤 Konser",
        "🎪 Festival", "🎶 Karaoke", "♟️ Satranç", "🧶 Örgü", "🏺 Seramik",
        "🎣 Balık tutma", "🧗 Dağcılık", "🤿 Dalış", "🧺 Piknik", "🌃 Gece hayatı",
    ]

    // ── Üretilen fotoğraf (görünüm adımlarından sonra, geçmiş adımından önce) ──
    @State private var generatedPhotoURL: String?
    @State private var photoGenError: String?

    // ── Result ──
    @State private var created: Character?

    // Önce bulanık dummy resim gelir; "See character"a basınca gerçek fotoğraf
    // üretilir (istek atılır) ve netleşir.
    @State private var photoRevealed = false
    @State private var generating = false
    @State private var revealedImage: Image?  // gerçek fotoğraf (önceden indirilir)
    /// PRO olmayan kullanıcı "See character"a basınca açılır — gerçek üretim
    /// SADECE PRO ise başlar (bkz. reveal()). Paywall kapanınca PRO olduysa
    /// otomatik devam eder (bkz. onDismiss).
    @State private var showPaywall = false

    private enum Phase { case steps, generatingPhoto, photoPreview, creating, ready }

    private let columns2 = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let columns3 = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    // Sıra: 0=kategori 1=isim 2=etnik köken 3=yaş 4=tarz(vibe) 5=meslek
    //       6=ilgi alanları 7=saç stili 8=saç rengi 9=göz rengi 10=ten tonu 11=anı(geçmiş)
    // Fotoğraf ("kız kısmı") TÜM adımlar bittikten SONRA üretilir.
    private var totalSteps: Int { 13 }
    private var isLastStep: Bool { stepIndex == totalSteps - 1 }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                switch phase {
                case .steps:           stepsContent
                case .generatingPhoto: generatingPhotoContent
                case .photoPreview:    photoPreviewContent
                case .creating:        creatingContent
                case .ready:           readyContent
                }
            }
        }
        .tint(AppColor.pink)
        .sheet(isPresented: $showPaywall, onDismiss: {
            // Paywall kapandı — PRO oldularsa fotoğrafı hemen üret ve devam et.
            if PurchaseService.shared.isPro { reveal() }
        }) {
            PaywallHostView()
        }
    }

    /// Ortak duvar-saati nabzı (0..1). İki TimelineView(.animation) aynı display-link
    /// saatini okur → buton ve kenar birebir senkron yanıp söner.
    private func pulseOpacity(_ date: Date, base: Double, amp: Double) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        let s = (sin(t * 2 * .pi / 1.2) + 1) / 2   // periyot 1.2 sn
        return base - amp * s
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepsContent: some View {
        VStack(spacing: 0) {
            topBar
            if stepIndex == 1 || isLastStep {
                // İsim + geçmiş: başlık (ortalı) ve içerik birlikte dikeyde ortalanır.
                VStack {
                    Spacer(minLength: 0)
                    VStack(spacing: 16) {
                        Text(stepTitle)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        stepBody
                    }
                    .padding(.horizontal, 20)
                    Spacer(minLength: 0)
                }
            } else if stepIndex == 0 {
                // Kategori: başlık üstte, kartlar ekranı doldurur (altta 8px).
                stepHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 8)
                stepBody
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            } else {
                stepHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 4)
                ScrollView {
                    stepBody
                        .padding(.horizontal, 20)
                        .padding(.top, 22)
                        .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.top)
                .mask(scrollFadeMask)
            }
            continueButton
        }
    }

    /// Kaydırma kenarlarında yumuşak geçiş (üst + alt gradient). Üst fade dar
    /// tutuldu ki ilk satır (ör. hobiler) gradientin altında kalmasın.
    private var scrollFadeMask: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.03),
            .init(color: .black, location: 0.95),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private var stepHeader: some View {
        Text(stepTitle)
            .font(.system(size: 26, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch stepIndex {
        case 0: categoryStep                                                                      // Kategori
        case 1: nameStep                                                                          // İsim
        case 2: optionGrid(options: AppearanceOptions.ethnicities, binding: $selectedEthnicity, imageKey: "eth")   // Etnik köken
        case 3: optionGrid(options: AppearanceOptions.ageRanges, binding: $selectedAgeRange, imageKey: "age")      // Yaş
        case 4: moodStep                                                                          // Kişilik (rol+tarz birleşik)
        case 5: professionStep                                                                    // Meslek
        case 6: interestsStep                                                                     // İlgi alanları
        case 7: appearanceOptionGrid(options: AppearanceOptions.hairstyles, feature: .hairstyle, binding: $selectedHairstyle, imageKey: "hair")
        case 8: appearanceOptionGrid(options: AppearanceOptions.hairColors, feature: .hairColor, binding: $selectedHairColor, imageKey: "haircolor")
        case 9: eyeColorStep
        case 10: appearanceOptionGrid(options: AppearanceOptions.skinTones, feature: .skinTone, binding: $selectedSkinTone, imageKey: "skin")
        case 11: optionGrid(options: AppearanceOptions.bodyTypes, binding: $selectedBodyType, imageKey: "bodytype")     // Vücut tipi
        default: exHistoryStep                                                                    // Anı ekle (12)
        }
    }

    // MARK: Step 0 — Category (büyük, tek sütun, kaydırılabilir)

    private var categoryStep: some View {
        VStack(spacing: 14) {
            ForEach(["Realistic", "Fictional"], id: \.self) { opt in
                let selected = selectedCategory == opt
                Button { selectedCategory = opt } label: {
                    categoryCard(opt: opt, selected: selected)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Ekranı dolduran esnek yükseklikli kategori kartı (yüz daha iyi sığar).
    private func categoryCard(opt: String, selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(AppColor.card)
            .overlay {
                // 9:16 görselden yüz bandını göster: üstteki fazla boşluğu at, pencereyi
                // aşağı kaydır → saç + gözler + dudaklar görünür (kafadan aşağı).
                if let asset = BuilderImages.asset("cat", opt) {
                    // Gerçekçi görselde üstte fazla boşluk var → biraz daha aşağı kaydır.
                    let bias: CGFloat = opt == "Realistic" ? 0.30 : 0.22
                    GeometryReader { geo in
                        Image(asset).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                            .offset(y: -geo.size.height * bias)
                    }
                    .clipped()
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                Text(AppearanceOptions.tr(opt))
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white).padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18)
                .strokeBorder(selected ? AppColor.pink : .white.opacity(0.12), lineWidth: selected ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                        .foregroundStyle(AppColor.pink).padding(8)
                        .background(Circle().fill(.white).padding(10))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Step 1 — Name

    private var nameStep: some View {
        VStack(spacing: 16) {
            TextField("", text: $characterName,
                      prompt: Text("Enter a name…").foregroundColor(.white.opacity(0.4)))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .tint(AppColor.pink)
                .multilineTextAlignment(.center)
                .padding(.vertical, 18)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(characterName.isEmpty ? .white.opacity(0.1) : AppColor.pink.opacity(0.6),
                                      lineWidth: 1.5)
                )
                .autocorrectionDisabled()
        }
        .padding(.top, 12)
    }

    // MARK: Step 1 — Role

    private var roleStep: some View {
        LazyVGrid(columns: columns2, spacing: 12) {
            ForEach(roleOptions) { role in
                let selected = selectedRole == role.id
                Button { selectedRole = role.id } label: {
                    VStack(spacing: 8) {
                        Text(role.emoji)
                            .font(.system(size: 30))
                        Text(role.label)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Text(role.description)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: selected
                                ? [AppColor.pink.opacity(0.45), AppColor.amber.opacity(0.45)]
                                : [Color.white.opacity(0.06), Color.white.opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(selected ? AppColor.pink : .white.opacity(0.1),
                                          lineWidth: selected ? 2 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(AppColor.pink)
                                .padding(8)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Step 4 — Mood (personality: role + vibe merged)

    private var moodStep: some View {
        LazyVGrid(columns: columns2, spacing: 12) {
            ForEach(personalityOptions) { p in
                let selected = selectedRole == p.role && selectedVibe == p.vibe
                Button {
                    selectedRole = p.role
                    selectedVibe = p.vibe
                } label: {
                    moodCard(p, selected: selected)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Reuses the 4 existing vibe photos (Sweet/Mysterious/Energetic/Elegant) — every
    /// personality maps to one, so no card art is missing. Two labels on top of the photo:
    /// the personality name (bottom, matches every other image card in this wizard) and a
    /// small vibe tag (top) so the reused photo's mood is still legible on its own — both
    /// sit on a ~40%-opaque colored plate rather than relying on the photo's own contrast,
    /// since the same 4 photos now appear under very different personalities/crops.
    private func moodCard(_ p: PersonalityOption, selected: Bool) -> some View {
        let height = cardHeight(for: "vibe")
        return ZStack(alignment: .bottomLeading) {
            if let asset = BuilderImages.asset("vibe", p.vibe) {
                Image(asset).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: height).clipped()
            } else {
                AppColor.card.frame(height: height)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 4) {
                Text(p.label)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(p.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)

            Text(Self.vibeLabel(p.vibe))
                .font(.system(size: 10, weight: .bold))
                .textCase(.uppercase)
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(AppColor.pink.opacity(0.4), in: Capsule())
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(selected ? AppColor.pink : .white.opacity(0.12), lineWidth: selected ? 3 : 1))
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                    .foregroundStyle(AppColor.pink).padding(8)
                    .background(Circle().fill(.white).padding(10))
            }
        }
    }

    /// The 4 vibe values are fixed/known — map each to its own `String(localized:)` literal
    /// (matches the existing catalog keys "Sweet"/"Mysterious"/"Energetic"/"Elegant") rather
    /// than building a `LocalizationValue` from a runtime string, so extraction/catalog
    /// lookup works the normal way.
    private static func vibeLabel(_ vibe: String) -> String {
        switch vibe {
        case "Sweet": return String(localized: "Sweet")
        case "Mysterious": return String(localized: "Mysterious")
        case "Energetic": return String(localized: "Energetic")
        case "Elegant": return String(localized: "Elegant")
        default: return vibe
        }
    }

    // MARK: Step 4 — Profession

    private var professionStep: some View {
        LazyVGrid(columns: columns2, spacing: 12) {
            ForEach(professionOptions) { prof in
                let selected = selectedProfession == prof.id
                Button { selectedProfession = prof.id } label: {
                    if let asset = BuilderImages.asset("prof", prof.id) {
                        imageOptionCard(asset: asset, label: prof.label, selected: selected, height: cardHeight(for: "prof"))
                    } else {
                        textOptionCard(label: "\(prof.emoji) \(prof.label)", selected: selected)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Steps 2-5 — Generic option grid

    private func optionGrid(options: [String], binding: Binding<String>, imageKey: String? = nil) -> some View {
        LazyVGrid(columns: columns2, spacing: 12) {
            ForEach(options, id: \.self) { opt in
                let selected = binding.wrappedValue == opt
                Button { binding.wrappedValue = opt } label: {
                    if let key = imageKey, let asset = BuilderImages.asset(key, opt) {
                        imageOptionCard(asset: asset, label: AppearanceOptions.tr(opt), selected: selected, height: cardHeight(for: key))
                    } else {
                        textOptionCard(label: AppearanceOptions.tr(opt), selected: selected)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Görünüm adımları (görsel kart varsa görsel, yoksa FacePreview)

    private func appearanceOptionGrid(options: [String], feature: FacePreview.Feature, binding: Binding<String>, imageKey: String? = nil) -> some View {
        LazyVGrid(columns: columns2, spacing: 12) {
            ForEach(options, id: \.self) { opt in
                let selected = binding.wrappedValue == opt
                Button { binding.wrappedValue = opt } label: {
                    if let key = imageKey, let asset = BuilderImages.asset(key, opt) {
                        imageOptionCard(asset: asset, label: AppearanceOptions.tr(opt), selected: selected, height: cardHeight(for: key))
                    } else {
                        facePreviewOptionCard(feature: feature, value: opt, selected: selected)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Göz rengi — geniş (yatay) kartlar, alt alta tek sütun

    private var eyeColorStep: some View {
        VStack(spacing: 12) {
            ForEach(AppearanceOptions.eyeColors, id: \.self) { c in
                let selected = selectedEyeColor == c
                Button { selectedEyeColor = c } label: {
                    ZStack(alignment: .leading) {
                        if let asset = BuilderImages.asset("eyecolor", c) {
                            Image(asset).resizable().scaledToFill()
                                .frame(maxWidth: .infinity).frame(height: 96).clipped()
                        } else {
                            Color.white.opacity(0.06).frame(height: 96)
                        }
                        LinearGradient(colors: [.black.opacity(0.55), .clear],
                                       startPoint: .leading, endPoint: .center)
                        Text(AppearanceOptions.tr(c))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white).padding(.leading, 16)
                    }
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(selected ? AppColor.pink : .white.opacity(0.12), lineWidth: selected ? 3 : 1))
                    .overlay(alignment: .trailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22)).foregroundStyle(AppColor.pink)
                                .padding(.trailing, 12)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Ortak kart görünümleri

    /// Kart yüksekliği — saç/saç rengi/ten/yaş görselleri daha "uzaktan" görünsün
    /// diye daha uzun kart kullanılır (dikey 9:16 görselden daha fazlası görünür).
    private func cardHeight(for imageKey: String?) -> CGFloat {
        switch imageKey {
        case "hair", "haircolor", "skin", "age", "vibe", "prof", "bodytype": return 240
        default: return 180
        }
    }

    /// 9:16 görselli seçenek kartı (alt köşede etiket).
    private func imageOptionCard(asset: String, label: String, selected: Bool, height: CGFloat = 180) -> some View {
        ZStack(alignment: .bottomLeading) {
            Image(asset).resizable().scaledToFill()
                .frame(maxWidth: .infinity).frame(height: height).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            Text(label)
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .padding(10)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(selected ? AppColor.pink : .white.opacity(0.12), lineWidth: selected ? 3 : 1))
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                    .foregroundStyle(AppColor.pink).padding(8)
                    .background(Circle().fill(.white).padding(10))
            }
        }
    }

    private func textOptionCard(label: String, selected: Bool) -> some View {
        VStack { Spacer()
            Text(label).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white).multilineTextAlignment(.center)
            Spacer() }
        .frame(maxWidth: .infinity).frame(height: 90)
        .background(LinearGradient(colors: selected
            ? [AppColor.pink.opacity(0.45), AppColor.amber.opacity(0.45)]
            : [Color.white.opacity(0.06), Color.white.opacity(0.06)],
            startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(selected ? AppColor.pink : .white.opacity(0.1), lineWidth: selected ? 2 : 1))
    }

    private func facePreviewOptionCard(feature: FacePreview.Feature, value: String, selected: Bool) -> some View {
        VStack(spacing: 8) {
            facePreviewCard(feature: feature, value: value).frame(width: 56, height: 56)
            Text(AppearanceOptions.tr(value)).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.vertical, 14).frame(maxWidth: .infinity)
        .background(LinearGradient(colors: selected
            ? [AppColor.pink.opacity(0.45), AppColor.amber.opacity(0.45)]
            : [Color.white.opacity(0.06), Color.white.opacity(0.06)],
            startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(selected ? AppColor.pink : .white.opacity(0.1), lineWidth: selected ? 2 : 1))
    }

    /// Her kart SADECE o an karar verilen özelliği canlandırır — diğer tüm
    /// özellikler FacePreview içinde varsayılan/nötr kalır (bkz. FacePreview.swift).
    @ViewBuilder
    private func facePreviewCard(feature: FacePreview.Feature, value: String) -> some View {
        switch feature {
        case .hairstyle: FacePreview(highlight: .hairstyle, hairstyle: value)
        case .hairColor: FacePreview(highlight: .hairColor, hairColor: value)
        case .eyeShape:  FacePreview(highlight: .eyeShape, eyeShape: value)
        case .eyeColor:  FacePreview(highlight: .eyeColor, eyeColor: value)
        case .noseShape: FacePreview(highlight: .noseShape, noseShape: value)
        case .skinTone:  FacePreview(highlight: .skinTone, skinTone: value)
        }
    }

    // MARK: Step 12 — Geçmiş / Anılar

    private var exHistoryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(AppColor.pink)
                Text("This lets them remember your shared history")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }

            TextField("", text: $exHistory,
                      prompt: Text("Tell your story how you met, memories you share, anything you want them to know…")
                          .foregroundColor(.white.opacity(0.35)),
                      axis: .vertical)
                .lineLimit(5...12)
                .foregroundStyle(.white)
                .tint(AppColor.pink)
                .padding(16)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(exHistory.isEmpty ? .white.opacity(0.1) : AppColor.pink.opacity(0.5),
                                      lineWidth: 1.5)
                )

            HStack {
                Spacer()
                Button {
                    exHistory = ""
                    advance()
                } label: {
                    Text("Skip")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.pinkSoft)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Step 13 — İlgi Alanları (hobiler, çoklu seçim)

    /// En fazla seçilebilecek ilgi alanı sayısı.
    private let maxInterests = 10

    private var interestsStep: some View {
        LazyVGrid(columns: columns3, spacing: 10) {
            ForEach(Self.hobbies, id: \.self) { hobby in
                let on = selectedInterests.contains(hobby)
                let atMax = selectedInterests.count >= maxInterests
                Button {
                    if on { selectedInterests.remove(hobby) }
                    else if !atMax { selectedInterests.insert(hobby) }
                } label: {
                    Text(hobby)
                        .font(.system(size: 12, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? AppColor.pinkSoft : Color.white.opacity(0.85))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(on ? AppColor.pink.opacity(0.15) : Color.white.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(on ? AppColor.pink.opacity(0.4) : .white.opacity(0.12), lineWidth: 1))
                        .opacity(!on && atMax ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(!on && atMax)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Top bar

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button { back() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.08), in: Circle())
                }
                Spacer()
                Text("STEP \(stepIndex + 1) / \(totalSteps)")
                    .font(.system(size: 12, weight: .bold)).tracking(0.5)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.white.opacity(0.08), in: Circle())
                }
            }
            ProgressView(value: Double(stepIndex + 1), total: Double(totalSteps))
                .tint(AppColor.pink)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Continue button

    private var continueButton: some View {
        let enabled = stepIsValid
        return Button { advance() } label: {
            Group {
                if isLastStep {
                    Text("Create Character")
                } else {
                    Text("Continue")
                }
            }
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(
                    LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                   startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
                .opacity(enabled ? 1 : 0.4)
        }
        .disabled(!enabled)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Generating photo (after appearance steps, before history)

    private var generatingPhotoContent: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().tint(AppColor.pink).scaleEffect(1.6)
            Text("✨ Bringing \(characterName.isEmpty ? "your character" : characterName) to life…")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("Generating a photo based on your choices")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 40)
        .task { await generatePhoto() }
    }

    // MARK: - Photo preview (confirm, then continue to history — no regenerate,
    // one shot per character to control image-gen cost)

    @ViewBuilder
    private var photoPreviewContent: some View {
        VStack(spacing: 20) {
            Spacer()
            // Hata ekranı SADECE karakter hiç oluşturulamadıysa gösterilir; görsel
            // üretimi başarısız olsa bile fallback ile karakter oluştuğundan normal
            // akış (dummy resim + devam) sürer.
            if let error = photoGenError, created == nil, !generating {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(AppColor.pink)
                Text(error)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Button { reveal() } label: {
                    Text("Try Again")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(
                            LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                           startPoint: .leading, endPoint: .trailing),
                            in: Capsule())
                }
                .padding(.horizontal, 40)
            } else {
                // Üst başlık: açılınca yeşil çevrimiçi + ad/yaş, altında meslek emojili.
                // Öncesinde "{ad} hazırlanıyor/seni bekliyor ❤️".
                VStack(spacing: 4) {
                    if photoRevealed, let c = created {
                        HStack(spacing: 8) {
                            Circle().fill(Color.green)
                                .frame(width: 10, height: 10)
                                .shadow(color: .green.opacity(0.6), radius: 3)
                            Text(c.nameWithAge)
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        if let prof = c.profession, !prof.isEmpty {
                            Text("\(professionEmoji) \(prof)")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text(generating ? "\(builderName) hazırlanıyor" : "\(builderName) seni bekliyor")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                            Image(systemName: "heart.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.red)
                        }
                    }
                }

                // Önce bulanık dummy resim (hızlı). "See character"a / resme basınca
                // gerçek fotoğraf üretilir; hazır olunca yumuşakça netleşir.
                ZStack {
                    Group {
                        // Gerçek fotoğraf SADECE reveal olunca (blur 0 iken) gösterilir →
                        // gerçek resim asla bulanık görünmez. Öncesinde dummy (bulanık).
                        if photoRevealed, let img = revealedImage {
                            img.resizable().scaledToFill()
                        } else {
                            dummyPhoto
                        }
                    }
                    .frame(height: 380).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .blur(radius: photoRevealed ? 0 : 28)
                    .clipShape(RoundedRectangle(cornerRadius: 24))

                    // Sadece dokunma göstergesi (üretim sürerken spinner yok).
                    if !photoRevealed && !generating {
                        VStack(spacing: 8) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 30, weight: .semibold))
                            Text("Tap to see")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                    }
                }
                .frame(height: 380).frame(maxWidth: .infinity)
                // Hazırlanırken kenarlar yanıp söner (nabız gibi parlayan çerçeve).
                .overlay {
                    TimelineView(.animation) { tl in
                        RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(AppColor.pink, lineWidth: generating ? 3 : 1.5)
                            .shadow(color: AppColor.pink.opacity(generating ? 0.8 : 0), radius: 8)
                            // Buton ile aynı saatten → eş zamanlı yanıp söner.
                            .opacity(generating ? pulseOpacity(tl.date, base: 1.0, amp: 0.8) : 0.5)
                    }
                }
                .padding(.horizontal, 20)
                .contentShape(RoundedRectangle(cornerRadius: 24))
                .onTapGesture { reveal() }

                if let c = created {
                    // Karakter oluşturuldu → modalı kapat, sohbete gerçek (app
                    // çapındaki) NavigationStack üzerinden git — böylece chat'ten
                    // geri dönünce "hazır" ekranına değil, tüm sohbetler listesine düşer.
                    Button {
                        goToChat(with: c)
                    } label: {
                        Text("Continue")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 54)
                            .background(
                                LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                               startPoint: .leading, endPoint: .trailing),
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                } else {
                    Button { reveal() } label: {
                        TimelineView(.animation) { tl in
                            Text(generating ? "\(builderName) hazırlanıyor..." : "See character")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 54)
                                .background(
                                    LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                                   startPoint: .leading, endPoint: .trailing),
                                    in: Capsule())
                                // Kenarlarla aynı saatten → eş zamanlı yanıp söner.
                                .opacity(generating ? pulseOpacity(tl.date, base: 1.0, amp: 0.8) : 1.0)
                        }
                    }
                    .buttonStyle(.plain)   // disabled sistem karartması nabzı gizlemesin
                    .allowsHitTesting(!generating)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                }
            }
            Spacer()
        }
    }

    /// Gerçek fotoğraf gelene kadar gösterilecek bulanık dummy — seçilen tarz/
    /// etnik köken görselini kullanır (bulanık olduğu için yüz benzemesi yeter).
    @ViewBuilder
    private var dummyPhoto: some View {
        if let asset = BuilderImages.asset("vibe", selectedVibe) ?? BuilderImages.asset("eth", selectedEthnicity) {
            Image(asset).resizable().scaledToFill()
        } else {
            AppColor.card
        }
    }

    // MARK: - Creating (final — text-only, photo already made)

    private var creatingContent: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().tint(AppColor.pink).scaleEffect(1.6)
            Text("✨ Creating your AI character…")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("Finishing up \(characterName)'s personality")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 40)
        .task { await createCharacter() }
    }

    // MARK: - Ready

    @ViewBuilder
    private var readyContent: some View {
        if let c = created {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)

                ScrollView {
                    VStack(spacing: 16) {
                        Text("Your Character Is Ready!")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)

                        // Role badge
                        if let role = roleOptions.first(where: { $0.id == c.personalityRole }) {
                            HStack(spacing: 6) {
                                Text(role.emoji)
                                Text(role.label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(AppColor.pink)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(AppColor.pink.opacity(0.15), in: Capsule())
                        }

                        CachedImage(url: c.photoURL) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { AppColor.card }
                        .frame(height: 380).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24)
                            .strokeBorder(AppColor.pink.opacity(0.5), lineWidth: 1.5))

                        VStack(spacing: 4) {
                            Text(c.nameWithAge)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                            Text([c.profession, c.category].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.7))
                        }

                        Button {
                            goToChat(with: c)
                        } label: {
                            Text("Start Chatting")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 54)
                                .background(
                                    LinearGradient(colors: [AppColor.pink, AppColor.amber],
                                                   startPoint: .leading, endPoint: .trailing),
                                    in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 20).padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: - Helpers

    private var stepTitle: String {
        switch stepIndex {
        case 0: return String(localized: "Category")
        case 1: return String(localized: "Karakterine bir isim seç")
        case 2: return String(localized: "Ethnicity")
        case 3: return String(localized: "Age range")
        case 4: return String(localized: "Select Mood")
        case 5: return String(localized: "Profession")
        case 6: return String(localized: "Interests")
        case 7: return String(localized: "Hairstyle")
        case 8: return String(localized: "Hair color")
        case 9: return String(localized: "Eye color")
        case 10: return String(localized: "Skin tone")
        case 11: return String(localized: "Body type")
        default: return String(localized: "History & Memories")
        }
    }

    // Tüm altyazılar kaldırıldı — sade başlık.
    private var stepSubtitle: String { "" }

    private var stepIsValid: Bool {
        switch stepIndex {
        case 0: return !selectedCategory.isEmpty
        case 1: return !characterName.trimmingCharacters(in: .whitespaces).isEmpty
        case 2: return !selectedEthnicity.isEmpty
        case 3: return !selectedAgeRange.isEmpty
        case 4: return !selectedVibe.isEmpty
        case 5: return !selectedProfession.isEmpty
        case 6: return !selectedInterests.isEmpty // en az bir ilgi alanı
        case 7: return !selectedHairstyle.isEmpty
        case 8: return !selectedHairColor.isEmpty
        case 9: return !selectedEyeColor.isEmpty
        case 10: return !selectedSkinTone.isEmpty
        case 11: return !selectedBodyType.isEmpty
        default: return true // ex history is optional
        }
    }

    private func back() {
        if stepIndex == 0 { dismiss() } else { stepIndex -= 1 }
    }

    private func advance() {
        if isLastStep {
            // Tüm adımlar bitti → bulanık dummy resimli önizleme ekranı (henüz
            // istek atılmaz; kullanıcı "See character"a basınca üretilir).
            phase = .photoPreview
        } else {
            stepIndex += 1
        }
    }

    /// Modalı kapatır ve sohbeti app'in ana NavigationStack'i (MainTabView)
    /// üzerinden açar — chat kendi lokal stack'imizde değil, gerçek stack'te
    /// push edilsin ki geri tuşu "hazır" ekranına değil, sohbetler listesine dönsün.
    private func goToChat(with character: Character) {
        store.pendingTab = .chat
        store.pendingMeetRequest = MeetRequest(character: character, prefillText: "")
        dismiss()
    }

    /// "See character": gerçek fotoğrafı üretir + karakteri oluşturur, sonra
    /// bulanıklığı yumuşak animasyonla açar (createCharacter'ın fallback'i
    /// olduğu için görsel başarısız olsa bile karakter mutlaka oluşturulur).
    private func reveal() {
        guard !generating && created == nil else { return }
        guard PurchaseService.shared.tier != .none else { showPaywall = true; return }
        generating = true
        photoGenError = nil
        // @MainActor: tüm @State güncellemeleri ana thread'de olsun (arka planda
        // state değişimi UI'ı bozuyordu — "buga giriyor" sebebi buydu).
        Task { @MainActor in
            await generatePhoto()               // en iyi çaba (istek atılır)
            // Gerçek fotoğrafı ÖNCEDEN indir ki reveal anında dummy flaşlamasın.
            if let urlStr = generatedPhotoURL, let url = URL(string: urlStr) {
                var req = URLRequest(url: url)
                req.timeoutInterval = 20
                if let (data, _) = try? await URLSession.shared.data(for: req),
                   let ui = UIImage(data: data) {
                    revealedImage = Image(uiImage: ui)
                }
            }
            await createCharacter()             // her durumda karakteri oluştur
            generating = false
            photoRevealed = true                // blur animasyonsuz, anında kalkar
        }
    }

    /// İlk harf büyük, gerisi küçük ("MERVE" / "mErVe" → "Merve").
    private func capitalizedName(_ raw: String) -> String {
        let n = raw.trimmingCharacters(in: .whitespaces)
        guard let first = n.first else { return n }
        return first.uppercased() + n.dropFirst().lowercased()
    }

    /// Butonda / başlıkta gösterilecek isim (girilmemişse nötr).
    private var builderName: String {
        let n = capitalizedName(characterName)
        return n.isEmpty ? String(localized: "Karakter") : n
    }

    /// Seçilen mesleğe uygun emoji (profession seçenek listesinden).
    private var professionEmoji: String {
        professionOptions.first(where: { $0.id == selectedProfession })?.emoji ?? "💼"
    }

    @MainActor
    private func generatePhoto() async {
        photoGenError = nil
        let service = CharacterCreateService()
        if let url = await service.generateImage(
            hairstyle: selectedHairstyle,
            hairColor: selectedHairColor,
            eyeShape: selectedEyeShape,
            eyeColor: selectedEyeColor,
            noseShape: selectedNoseShape,
            skinTone: selectedSkinTone,
            bodyType: selectedBodyType,
            category: selectedCategory,
            vibe: selectedVibe,
            profession: selectedProfession,
            personalityRole: selectedRole,
            ageRange: selectedAgeRange,
            ethnicity: selectedEthnicity
        ) {
            generatedPhotoURL = url
        } else {
            photoGenError = String(localized: "Couldn't generate your character's photo. Please try again.")
        }
    }

    @MainActor
    private func createCharacter() async {
        let service = CharacterCreateService()
        let photo = generatedPhotoURL ?? ""
        let history = exHistory.trimmingCharacters(in: .whitespaces)

        let outcome = await service.create(
            name: capitalizedName(characterName),
            photoUrl: photo,
            personalityRole: selectedRole,
            category: selectedCategory,
            vibe: selectedVibe,
            profession: selectedProfession,
            ageRange: selectedAgeRange,
            hairstyle: selectedHairstyle,
            hairColor: selectedHairColor,
            eyeShape: selectedEyeShape,
            eyeColor: selectedEyeColor,
            noseShape: selectedNoseShape,
            skinTone: selectedSkinTone,
            bodyType: selectedBodyType,
            exHistory: history.isEmpty ? nil : history,
            interests: Array(selectedInterests),
            ethnicity: selectedEthnicity
        )

        switch outcome {
        case .success(let c):
            withAnimation { created = c }
            store.characters.append(c)
            return
        case .rejected(let errorCode):
            // Sunucu bilerek reddetti (abonelik yok / haftalık hak bitti) —
            // ASLA yerel-sadece bir fallback karakter oluşturma, bu gating'i
            // tamamen atlar (bkz. create-character/index.ts checkCreationAllowance).
            photoRevealed = true
            photoGenError = errorCode == "weekly_limit_reached"
                ? String(localized: "You've used all your character slots this week.")
                : String(localized: "Subscribe to create characters.")
            showPaywall = errorCode != "weekly_limit_reached"
            return
        case .networkFailure:
            break // aşağıdaki yerel fallback'e düş
        }

        // Fallback: local character if server unreachable — üretilmiş fotoğraf
        // varsa (görüntü üretimi başarılı oldu ama son kayıt çağrısı başarısız
        // oldu) onu kullan, yoksa fotoğrafsız devam et.
        let fallback = Character(
            id: UUID(),
            name: characterName.isEmpty ? "Lumi" : capitalizedName(characterName),
            tagline: "\(selectedRole) · \(selectedProfession)",
            systemPrompt: "You are \(characterName). Personality: \(selectedRole). Vibe: \(selectedVibe). Reply warmly and naturally.",
            avatarSymbol: "sparkles",
            age: 23,
            profession: selectedProfession,
            category: selectedCategory,
            photoURL: URL(string: photo),
            avatarURL: URL(string: photo),
            interests: Array(selectedInterests),
            galleryURLs: [URL(string: photo)].compactMap { $0 },
            personalityRole: selectedRole
        )
        withAnimation { created = fallback }
        store.characters.append(fallback)
    }
}

#Preview {
    CreateCharacterView()
        .environment(CharacterStore())
}

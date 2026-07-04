//
//  CreateCharacterView.swift
//  Karakter yaratma sihirbazı — kullanıcı isim yazar, kişilik/kategori/vibe/
//  meslek/yaş + görünüm (saç/göz/burun/ten) özelliklerini seçer; AI bu
//  özelliklere göre bir fotoğraf + bio + system_prompt üretir.
//

import SwiftUI

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
    @State private var selectedRole = "flirty"
    @State private var selectedCategory = ""
    @State private var selectedVibe = ""
    @State private var selectedProfession = ""
    @State private var selectedAgeRange = ""
    @State private var selectedHairstyle = AppearanceOptions.hairstyles[0]
    @State private var selectedHairColor = AppearanceOptions.hairColors[0]
    @State private var selectedEyeShape = AppearanceOptions.eyeShapes[0]
    @State private var selectedEyeColor = AppearanceOptions.eyeColors[0]
    @State private var selectedNoseShape = AppearanceOptions.noseShapes[0]
    @State private var selectedSkinTone = AppearanceOptions.skinTones[0]
    @State private var exHistory = ""

    // ── Üretilen fotoğraf (görünüm adımlarından sonra, geçmiş adımından önce) ──
    @State private var generatedPhotoURL: String?
    @State private var photoGenError: String?

    // ── Result ──
    @State private var created: Character?

    private enum Phase { case steps, generatingPhoto, photoPreview, creating, ready }

    private let columns2 = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let columns3 = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    // Steps: 0=name 1=role 2=category 3=vibe 4=profession 5=ageRange
    //        6=hairstyle 7=hairColor 8=eyeShape 9=eyeColor 10=noseShape 11=skinTone
    //        12=history
    private var totalSteps: Int { 13 }
    private var isLastStep: Bool { stepIndex == totalSteps - 1 }
    /// Son görünüm adımı (ten tonu) — buradan çıkınca fotoğraf üretimi tetiklenir,
    /// normal adım artışı değil.
    private let appearanceEndIndex = 11

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
            .navigationDestination(for: Character.self) { ChatView(character: $0) }
        }
        .tint(AppColor.pink)
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepsContent: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 4) {
                    stepHeader
                    stepBody
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            continueButton
        }
    }

    private var stepHeader: some View {
        Group {
            Text(stepTitle)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 8)
            Text(stepSubtitle)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch stepIndex {
        case 0: nameStep
        case 1: roleStep
        case 2: optionGrid(options: ["Realistic", "Fantasy", "Anime", "Sci-Fi"],
                           binding: $selectedCategory)
        case 3: optionGrid(options: ["Sweet", "Mysterious", "Energetic", "Elegant"],
                           binding: $selectedVibe)
        case 4: professionStep
        case 5: optionGrid(options: ["18-21", "22-25", "26-30"],
                           binding: $selectedAgeRange)
        case 6: appearanceOptionGrid(options: AppearanceOptions.hairstyles, feature: .hairstyle, binding: $selectedHairstyle)
        case 7: appearanceOptionGrid(options: AppearanceOptions.hairColors, feature: .hairColor, binding: $selectedHairColor)
        case 8: appearanceOptionGrid(options: AppearanceOptions.eyeShapes, feature: .eyeShape, binding: $selectedEyeShape)
        case 9: appearanceOptionGrid(options: AppearanceOptions.eyeColors, feature: .eyeColor, binding: $selectedEyeColor)
        case 10: appearanceOptionGrid(options: AppearanceOptions.noseShapes, feature: .noseShape, binding: $selectedNoseShape)
        case 11: appearanceOptionGrid(options: AppearanceOptions.skinTones, feature: .skinTone, binding: $selectedSkinTone)
        default: exHistoryStep
        }
    }

    // MARK: Step 0 — Name

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

            Text("This name will always be used")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
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

    // MARK: Step 4 — Profession

    private var professionStep: some View {
        LazyVGrid(columns: columns3, spacing: 10) {
            ForEach(professionOptions) { prof in
                let selected = selectedProfession == prof.id
                Button { selectedProfession = prof.id } label: {
                    VStack(spacing: 6) {
                        Text(prof.emoji)
                            .font(.system(size: 26))
                        Text(prof.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        LinearGradient(
                            colors: selected
                                ? [AppColor.pink.opacity(0.45), AppColor.amber.opacity(0.45)]
                                : [Color.white.opacity(0.06), Color.white.opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(selected ? AppColor.pink : .white.opacity(0.1),
                                          lineWidth: selected ? 2 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(AppColor.pink)
                                .padding(6)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Steps 2-5 — Generic option grid

    private func optionGrid(options: [String], binding: Binding<String>) -> some View {
        LazyVGrid(columns: columns2, spacing: 12) {
            ForEach(options, id: \.self) { opt in
                let selected = binding.wrappedValue == opt
                Button { binding.wrappedValue = opt } label: {
                    VStack {
                        Spacer()
                        Text(LocalizedStringKey(opt))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 90)
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

    // MARK: Steps 6-11 — Appearance option grid (with FacePreview)

    private func appearanceOptionGrid(options: [String], feature: FacePreview.Feature, binding: Binding<String>) -> some View {
        LazyVGrid(columns: columns2, spacing: 12) {
            ForEach(options, id: \.self) { opt in
                let selected = binding.wrappedValue == opt
                Button { binding.wrappedValue = opt } label: {
                    VStack(spacing: 8) {
                        facePreviewCard(feature: feature, value: opt)
                            .frame(width: 56, height: 56)
                        Text(LocalizedStringKey(opt))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.vertical, 14)
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
                      prompt: Text("Tell your story — how you met, memories you share, anything you want them to know…")
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
                Text("Optional.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button {
                    exHistory = ""
                    advance()
                } label: {
                    Text("Leave blank, skip")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppColor.pinkSoft)
                        .underline()
                }
                .buttonStyle(.plain)
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
            if let error = photoGenError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(AppColor.pink)
                Text(error)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Button { phase = .generatingPhoto } label: {
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
            } else if let urlString = generatedPhotoURL, let url = URL(string: urlString) {
                Text("Here's your character 👀")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)

                CachedImage(url: url) { img in
                    img.resizable().scaledToFill()
                } placeholder: { AppColor.card }
                .frame(height: 380).frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(AppColor.pink.opacity(0.5), lineWidth: 1.5))
                .padding(.horizontal, 20)

                Button {
                    stepIndex = totalSteps - 1 // geçmiş adımı
                    phase = .steps
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
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
            Spacer()
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
                        Text("✨ Your Character Is Ready!")
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

                        NavigationLink(value: c) {
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
            }
        }
    }

    // MARK: - Helpers

    private var stepTitle: String {
        switch stepIndex {
        case 0: return String(localized: "Give a name")
        case 1: return String(localized: "Pick a personality")
        case 2: return String(localized: "Category")
        case 3: return String(localized: "Vibe")
        case 4: return String(localized: "Profession")
        case 5: return String(localized: "Age range")
        case 6: return String(localized: "Hairstyle")
        case 7: return String(localized: "Hair color")
        case 8: return String(localized: "Eye shape")
        case 9: return String(localized: "Eye color")
        case 10: return String(localized: "Nose shape")
        case 11: return String(localized: "Skin tone")
        default: return String(localized: "History & Memories")
        }
    }

    private var stepSubtitle: String {
        switch stepIndex {
        case 0: return String(localized: "What should your character be named?")
        case 1: return String(localized: "This defines their core personality")
        case 2: return String(localized: "Which world are they from?")
        case 3: return String(localized: "What's their overall vibe?")
        case 4: return String(localized: "What do they do for work?")
        case 5: return String(localized: "How old should they be?")
        case 6: return String(localized: "How do they wear their hair?")
        case 7: return String(localized: "What color is their hair?")
        case 8: return String(localized: "What shape are their eyes?")
        case 9: return String(localized: "What color are their eyes?")
        case 10: return String(localized: "What shape is their nose?")
        case 11: return String(localized: "What's their skin tone?")
        default: return String(localized: "Optional — tell your story")
        }
    }

    private var stepIsValid: Bool {
        switch stepIndex {
        case 0: return !characterName.trimmingCharacters(in: .whitespaces).isEmpty
        case 1: return true  // role always has a default
        case 2: return !selectedCategory.isEmpty
        case 3: return !selectedVibe.isEmpty
        case 4: return !selectedProfession.isEmpty
        case 5: return !selectedAgeRange.isEmpty
        case 6: return !selectedHairstyle.isEmpty
        case 7: return !selectedHairColor.isEmpty
        case 8: return !selectedEyeShape.isEmpty
        case 9: return !selectedEyeColor.isEmpty
        case 10: return !selectedNoseShape.isEmpty
        case 11: return !selectedSkinTone.isEmpty
        default: return true // ex history is optional
        }
    }

    private func back() {
        if stepIndex == 0 { dismiss() } else { stepIndex -= 1 }
    }

    private func advance() {
        if stepIndex == appearanceEndIndex {
            // Ten tonundan sonra: fotoğraf üretimine geç, normal adım artışı değil.
            phase = .generatingPhoto
        } else if isLastStep {
            phase = .creating
        } else {
            stepIndex += 1
        }
    }

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
            category: selectedCategory,
            vibe: selectedVibe,
            profession: selectedProfession,
            personalityRole: selectedRole,
            ageRange: selectedAgeRange
        ) {
            generatedPhotoURL = url
        } else {
            photoGenError = String(localized: "Couldn't generate your character's photo. Please try again.")
        }
        phase = .photoPreview
    }

    private func createCharacter() async {
        let service = CharacterCreateService()
        let photo = generatedPhotoURL ?? ""
        let history = exHistory.trimmingCharacters(in: .whitespaces)

        if let c = await service.create(
            name: characterName.trimmingCharacters(in: .whitespaces),
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
            exHistory: history.isEmpty ? nil : history
        ) {
            created = c
            store.characters.append(c)
            phase = .ready
            return
        }

        // Fallback: local character if server unreachable — üretilmiş fotoğraf
        // varsa (görüntü üretimi başarılı oldu ama son kayıt çağrısı başarısız
        // oldu) onu kullan, yoksa fotoğrafsız devam et.
        let fallback = Character(
            id: UUID(),
            name: characterName.isEmpty ? "Lumi" : characterName,
            tagline: "\(selectedRole) · \(selectedProfession)",
            systemPrompt: "You are \(characterName). Personality: \(selectedRole). Vibe: \(selectedVibe). Reply warmly and naturally.",
            avatarSymbol: "sparkles",
            age: 23,
            profession: selectedProfession,
            category: selectedCategory,
            photoURL: URL(string: photo),
            avatarURL: URL(string: photo),
            galleryURLs: [URL(string: photo)].compactMap { $0 },
            personalityRole: selectedRole
        )
        created = fallback
        store.characters.append(fallback)
        phase = .ready
    }
}

#Preview {
    CreateCharacterView()
        .environment(CharacterStore())
}

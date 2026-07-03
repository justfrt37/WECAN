//
//  CreateCharacterView.swift
//  Karakter yaratma sihirbazı — kullanıcı isim yazar, fotoğraf seçer,
//  rol + özelliklerini belirler; AI bio + system_prompt üretir.
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
    .init(id: "flirty",  emoji: "💋", label: "Flirty",   description: "Forward & charming from day one"),
    .init(id: "distant", emoji: "❄️", label: "Distant",  description: "Cold at first, slow to open up"),
    .init(id: "shy",     emoji: "🌸", label: "Shy",      description: "Nervous & sweet, gains confidence"),
    .init(id: "playful", emoji: "😏", label: "Playful",  description: "Witty banter, jokes & teasing"),
    .init(id: "devoted", emoji: "🥰", label: "Devoted",  description: "Deep attachment from the start"),
    .init(id: "crazy",   emoji: "🔥", label: "Crazy",    description: "Intense love, always overthinking"),
    .init(id: "ex",      emoji: "💔", label: "The Ex",   description: "Acts like she's moved on… hasn't"),
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
    @State private var selectedPhotoUrl: String? = nil
    @State private var selectedRole = "flirty"
    @State private var selectedCategory = ""
    @State private var selectedVibe = ""
    @State private var selectedProfession = ""
    @State private var selectedAgeRange = ""
    @State private var exHistory = ""

    // ── Result ──
    @State private var created: Character?

    private enum Phase { case steps, creating, ready }

    private let columns2 = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let columns3 = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    // Steps: 0=name 1=photo 2=role 3=category 4=vibe 5=profession 6=ageRange 7=history
    private var totalSteps: Int { 8 }
    private var isLastStep: Bool { stepIndex == totalSteps - 1 }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                switch phase {
                case .steps:    stepsContent
                case .creating: creatingContent
                case .ready:    readyContent
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
        case 1: photoStep
        case 2: roleStep
        case 3: optionGrid(options: ["Realistic", "Fantasy", "Anime", "Sci-Fi"],
                           binding: $selectedCategory)
        case 4: optionGrid(options: ["Sweet", "Mysterious", "Energetic", "Elegant"],
                           binding: $selectedVibe)
        case 5: optionGrid(options: ["Student", "Artist", "Warrior", "Scientist", "Musician"],
                           binding: $selectedProfession)
        case 6: optionGrid(options: ["18-21", "22-25", "26-30"],
                           binding: $selectedAgeRange)
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

    // MARK: Step 1 — Photo

    private var photoStep: some View {
        LazyVGrid(columns: columns2, spacing: 14) {
            ForEach(CharacterCreateService.availablePhotos, id: \.url) { photo in
                let selected = selectedPhotoUrl == photo.url
                Button {
                    selectedPhotoUrl = photo.url
                } label: {
                    ZStack(alignment: .bottom) {
                        CachedImage(url: URL(string: photo.url)) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            AppColor.card
                        }
                        .frame(height: 200)
                        .clipped()

                        // Label overlay
                        Text(photo.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.45))
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(selected ? AppColor.pink : .white.opacity(0.1),
                                          lineWidth: selected ? 2.5 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(AppColor.pink)
                                .padding(8)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Step 2 — Role

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

    // MARK: Steps 3-6 — Generic option grid

    private func optionGrid(options: [String], binding: Binding<String>) -> some View {
        LazyVGrid(columns: columns2, spacing: 12) {
            ForEach(options, id: \.self) { opt in
                let selected = binding.wrappedValue == opt
                Button { binding.wrappedValue = opt } label: {
                    VStack {
                        Spacer()
                        Text(opt)
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

    // MARK: Step 7 — Geçmiş / Anılar

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
            Text(isLastStep ? "Create Character" : "Continue")
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

    // MARK: - Creating

    private var creatingContent: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().tint(AppColor.pink).scaleEffect(1.6)
            Text("✨ Creating your AI character…")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("Preparing \(characterName) based on your choices")
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
        case 0: return "Give a name"
        case 1: return "Pick a photo"
        case 2: return "Pick a personality"
        case 3: return "Category"
        case 4: return "Vibe"
        case 5: return "Profession"
        case 6: return "Age range"
        default: return "History & Memories"
        }
    }

    private var stepSubtitle: String {
        switch stepIndex {
        case 0: return "What should your character be named?"
        case 1: return "Pick from the available photos for now"
        case 2: return "This defines their core personality"
        case 3: return "Which world are they from?"
        case 4: return "What's their overall vibe?"
        case 5: return "What do they do for work?"
        case 6: return "How old should they be?"
        default: return "Optional — tell your story"
        }
    }

    private var stepIsValid: Bool {
        switch stepIndex {
        case 0: return !characterName.trimmingCharacters(in: .whitespaces).isEmpty
        case 1: return selectedPhotoUrl != nil
        case 2: return true  // role always has a default
        case 3: return !selectedCategory.isEmpty
        case 4: return !selectedVibe.isEmpty
        case 5: return !selectedProfession.isEmpty
        case 6: return !selectedAgeRange.isEmpty
        default: return true // ex history is optional
        }
    }

    private func back() {
        if stepIndex == 0 { dismiss() } else { stepIndex -= 1 }
    }

    private func advance() {
        if isLastStep {
            phase = .creating
        } else {
            stepIndex += 1
        }
    }

    private func createCharacter() async {
        let service = CharacterCreateService()
        let photo = selectedPhotoUrl ?? CharacterCreateService.availablePhotos[0].url
        let history = exHistory.trimmingCharacters(in: .whitespaces)

        if let c = await service.create(
            name: characterName.trimmingCharacters(in: .whitespaces),
            photoUrl: photo,
            personalityRole: selectedRole,
            category: selectedCategory,
            vibe: selectedVibe,
            profession: selectedProfession,
            ageRange: selectedAgeRange,
            exHistory: history.isEmpty ? nil : history
        ) {
            created = c
            store.characters.append(c)
            phase = .ready
            return
        }

        // Fallback: local character if server unreachable
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

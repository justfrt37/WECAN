//
//  CreateCharacterView.swift
//  "Kendi karakterini yarat" akışı (çok adımlı sihirbaz).
//  Tasarım: AIGUI .pen "Lumi - Karakter Yarat 1..8" + "Karakter Hazır".
//  Adımlar: kimlik → etnik köken → saç → göz → kişilik → ilgi alanları →
//           ilişki türü → senaryo → (AI oluşturuyor) → karakter hazır.
//  Görseller dummy; PRO kilidi şimdilik yok (karakter direkt gösterilir).
//

import SwiftUI

struct CreateCharacterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CharacterStore.self) private var store

    private struct Step {
        let title: String
        let subtitle: String
        let options: [String]
        let multi: Bool
    }

    private let steps: [Step] = [
        .init(title: "Karakterini yarat", subtitle: "Önce kimliğini seç",
              options: ["👩 Kadın", "👨 Erkek", "🧑 Non-binary", "✨ Sürpriz"], multi: false),
        .init(title: "Etnik köken", subtitle: "Görünümünü belirle",
              options: ["Avrupalı", "Asyalı", "Afrikalı", "Latin", "Orta Doğu", "Karışık"], multi: false),
        .init(title: "Saç rengi", subtitle: "Saçı nasıl olsun?",
              options: ["Siyah", "Kahverengi", "Sarışın", "Kızıl", "Pembe", "Mavi"], multi: false),
        .init(title: "Göz rengi", subtitle: "Gözleri nasıl olsun?",
              options: ["Kahve", "Mavi", "Yeşil", "Ela", "Gri", "Mor"], multi: false),
        .init(title: "Kişiliğini seç", subtitle: "Nasıl bir karakter?",
              options: ["Romantik", "Eğlenceli", "Utangaç", "Tutkulu", "Sakin", "Esprili"], multi: false),
        .init(title: "İlgi alanları", subtitle: "Birkaç tane seçebilirsin",
              options: ["Müzik", "Sinema", "Seyahat", "Spor", "Sanat", "Yemek", "Oyun", "Kitap", "Dans", "Doğa"], multi: true),
        .init(title: "İlişki türü", subtitle: "Aranızdaki bağ ne olsun?",
              options: ["Sevgili", "Flört", "Arkadaş", "Evlilik"], multi: false),
        .init(title: "Senaryo seç", subtitle: "Hikayeniz nasıl başlasın?",
              options: ["İlk tanışma", "Tatil romantizmi", "Kafede buluşma", "Uzun mesafe", "Ofis aşkı"], multi: false),
    ]

    @State private var stepIndex = 0
    @State private var selections: [Int: Set<String>] = [:]
    @State private var phase: Phase = .steps
    @State private var created: Character?

    // Senaryo adımı: kendi metni + AI üretimi
    @State private var customScenario = ""
    @State private var isGenerating = false
    private let generator = GenerateService()

    private var scenarioStepIndex: Int { steps.count - 1 }

    private enum Phase { case steps, creating, ready }

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [AppColor.bg, AppColor.bg2, AppColor.bg],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                switch phase {
                case .steps:    stepContent
                case .creating: creatingContent
                case .ready:    readyContent
                }
            }
            .navigationDestination(for: Character.self) { ChatView(character: $0) }
        }
        .tint(AppColor.pink)
    }

    // MARK: Adım ekranı

    private var stepContent: some View {
        let step = steps[stepIndex]
        return VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 4) {
                    Text(step.title)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                    Text(step.subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.bottom, 20)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(step.options, id: \.self) { opt in
                            optionCard(opt, step: step)
                        }
                    }

                    if stepIndex == scenarioStepIndex {
                        customScenarioSection
                            .padding(.top, 18)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }

            continueButton
        }
    }

    /// Senaryo adımı: kendi senaryonu yaz + AI ile öner.
    private var customScenarioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("veya kendin yaz")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button {
                    Task { await generateScenario() }
                } label: {
                    HStack(spacing: 6) {
                        if isGenerating {
                            ProgressView().tint(.white).scaleEffect(0.7)
                        } else {
                            Image(systemName: "sparkles").font(.system(size: 13))
                        }
                        Text(isGenerating ? "Üretiliyor…" : "AI ile öner")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(
                        LinearGradient(colors: [AppColor.pink, Color(hex: 0xC4A7E7)],
                                       startPoint: .leading, endPoint: .trailing),
                        in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isGenerating)
            }

            TextField("", text: $customScenario,
                      prompt: Text("Kendi başlangıç senaryonu yaz…").foregroundColor(.white.opacity(0.4)),
                      axis: .vertical)
                .lineLimit(3...8)
                .foregroundStyle(.white)
                .tint(AppColor.pink)
                .padding(14)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(customScenario.isEmpty ? .white.opacity(0.1) : AppColor.pink.opacity(0.5),
                                      lineWidth: 1)
                )
                .onChange(of: customScenario) {
                    // Kendi metni yazınca hazır seçim kalksın (çakışmasın).
                    if !customScenario.isEmpty { selections[scenarioStepIndex] = [] }
                }
        }
    }

    private func generateScenario() async {
        isGenerating = true
        let g = sel(0); let personality = sel(4)
        let prompt = """
        Bir yapay zeka sohbet uygulaması için TEK paragraflık, kısa (en fazla 2 cümle), \
        sıcak ve romantik bir sohbet başlangıç senaryosu yaz. Türkçe yaz, tırnak işareti kullanma. \
        Karakter kişiliği: \(personality.isEmpty ? "romantik" : personality). \
        Kimlik: \(g.isEmpty ? "kadın" : g).
        """
        if let text = await generator.generate(prompt: prompt, maxTokens: 120) {
            customScenario = text
            selections[scenarioStepIndex] = []
        }
        isGenerating = false
    }

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button { back() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 36, height: 36)
                        .background(.white.opacity(0.08), in: Circle())
                }
                Spacer()
                Text("ADIM \(stepIndex + 1) / \(steps.count)")
                    .font(.system(size: 12, weight: .bold)).tracking(0.5)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 36, height: 36)
                        .background(.white.opacity(0.08), in: Circle())
                }
            }
            ProgressView(value: Double(stepIndex + 1), total: Double(steps.count))
                .tint(AppColor.pink)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func optionCard(_ opt: String, step: Step) -> some View {
        let selected = selections[stepIndex]?.contains(opt) ?? false
        return Button {
            toggle(opt, multi: step.multi)
        } label: {
            VStack {
                Spacer()
                Text(opt)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .background(
                LinearGradient(colors: selected
                               ? [AppColor.pink.opacity(0.5), Color(hex: 0x7A3FA0).opacity(0.5)]
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
                        .font(.system(size: 20)).foregroundStyle(AppColor.pink)
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var continueButton: some View {
        var hasSelection = !(selections[stepIndex]?.isEmpty ?? true)
        if stepIndex == scenarioStepIndex && !customScenario.trimmingCharacters(in: .whitespaces).isEmpty {
            hasSelection = true
        }
        return Button {
            advance()
        } label: {
            Text(stepIndex == steps.count - 1 ? "Karakteri Oluştur" : "Devam et")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 54)
                .background(
                    LinearGradient(colors: [AppColor.pink, Color(hex: 0xC4A7E7)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
                .opacity(hasSelection ? 1 : 0.4)
        }
        .disabled(!hasSelection)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: AI oluşturuyor

    private var creatingContent: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView().tint(AppColor.pink).scaleEffect(1.6)
            Text("✨ AI karakterini yaratıyor…")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            Text("Seçimlerine göre sana özel biri hazırlanıyor")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 40)
        .task {
            await createCharacter()
        }
    }

    // MARK: Karakter Hazır

    @ViewBuilder
    private var readyContent: some View {
        if let c = created {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white).frame(width: 36, height: 36)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)

                ScrollView {
                    VStack(spacing: 16) {
                        Text("✨ AI ile yaratıldı")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xFFB938))
                        Text("Karakterin Hazır!")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)

                        CachedImage(url: c.photoURL) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { AppColor.card }
                        .frame(height: 380)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(AppColor.pink.opacity(0.5), lineWidth: 1.5))
                        .padding(.top, 6)

                        VStack(spacing: 4) {
                            Text(c.nameWithAge)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                            Text([c.profession, c.locationText].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.7))
                        }

                        NavigationLink(value: c) {
                            Text("Sohbete Başla")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 54)
                                .background(
                                    LinearGradient(colors: [AppColor.pink, Color(hex: 0xC4A7E7)],
                                                   startPoint: .leading, endPoint: .trailing),
                                    in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
        }
    }

    // MARK: Aksiyonlar

    private func toggle(_ opt: String, multi: Bool) {
        var set = selections[stepIndex] ?? []
        if multi {
            if set.contains(opt) { set.remove(opt) } else { set.insert(opt) }
        } else {
            set = [opt]
        }
        selections[stepIndex] = set
    }

    private func back() {
        if stepIndex == 0 { dismiss() } else { stepIndex -= 1 }
    }

    private func advance() {
        if stepIndex < steps.count - 1 {
            stepIndex += 1
        } else {
            phase = .creating
        }
    }

    private func sel(_ i: Int) -> String { selections[i]?.first ?? "" }

    /// AI ile karakter yaratıp Supabase'e kaydeder (create-character fn).
    /// Hata olursa yerel yedek karakter üretir (akış takılmasın).
    private func createCharacter() async {
        let scenario = customScenario.trimmingCharacters(in: .whitespaces).isEmpty ? sel(7) : customScenario
        let interests = Array(selections[5] ?? [])

        let service = CharacterCreateService()
        if let c = await service.create(
            gender: sel(0), ethnicity: sel(1), hair: sel(2), eye: sel(3),
            personality: sel(4), interests: interests, relationship: sel(6),
            scenario: scenario
        ) {
            created = c
            store.characters.append(c)
            phase = .ready
            return
        }
        // Yedek: sunucu erişilemezse yerel karakter (kaydedilmez).
        created = fallbackCharacter(scenario: scenario, interests: interests)
        if let c = created { store.characters.append(c) }
        phase = .ready
    }

    private func fallbackCharacter(scenario: String, interests: [String]) -> Character {
        let isFemale = sel(0).contains("Kadın") || sel(0).contains("Sürpriz")
        let names = isFemale ? ["Lana", "Mira", "Ada", "Selin", "Noa"] : ["Kai", "Aron", "Eren", "Leo"]
        let name = names.randomElement() ?? "Lumi"
        let age = Int.random(in: 20...28)
        let personality = sel(4)
        let (photo, category) = CharacterCreateService.pickPhoto(hair: sel(2))
        let prompt = "Sen \(name)'sin, \(age) yaşında. Kişiliğin: \(personality). " +
            "Saç: \(sel(2)), göz: \(sel(3)), köken: \(sel(1)). İlgi alanların: \(interests.joined(separator: ", ")). " +
            (scenario.isEmpty ? "" : "Başlangıç senaryosu: \(scenario). ") +
            "Sıcak, doğal ve kısa cevaplar ver, karakterinden çıkma."
        var c = Character(
            id: UUID(), name: name, tagline: "\(personality) · \(sel(6))",
            systemPrompt: prompt, avatarSymbol: "sparkles", age: age,
            profession: personality,
            photoURL: URL(string: photo), avatarURL: URL(string: photo),
            interests: interests, relationshipLevel: 0,
            galleryURLs: URL(string: photo).map { [$0] } ?? []
        )
        c.category = category
        return c
    }
}

#Preview {
    CreateCharacterView()
        .environment(CharacterStore())
}

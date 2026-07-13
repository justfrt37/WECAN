//
//  OnboardingStore.swift
//  Onboarding akışının durumu + kalıcı verisi.
//
//  Kalıcı (UserDefaults): tamamlanma bayrağı, kullanıcı adı, seçilen karakter,
//  soru cevapları — ileride uygulamada kullanılmak üzere saklanır.
//  Geçici (bellekte): akışın hangi adımda olduğu (`step`).
//
//  Uygulama açılışında `isCompleted` false ise onboarding gösterilir; akış
//  bitince `complete()` çağrılır ve bir daha gösterilmez.
//

import Foundation
import Observation

/// Onboarding adımları. Sıra: Splash (ayrı) → name(ONB1) → socialProof(ONB2)
/// → characterSelect(ONB3) → questions(ONB3 içi) → ... → done.
enum OnboardingStep: Equatable {
    case name            // ONB1 — isim girişi (ob1Video arka plan)
    case socialProof     // ONB2 — social proof
    case characterSelect // ONB3 — karakter seçimi ("Birini seçin")
    case questions       // ONB4 — seçilen video üstünde 2 soru (4 sn timer)
    case finalTease      // ONB5 — "O bekliyor..." dokun-gör ekranı
    case paywall         // ONB6 — abonelik paywall'ı (seçilen kızın videosu arkada)
}

/// ONB3'te seçilebilen tanıtım karakterleri.
enum OnboardingCharacter: String, Equatable {
    case red    // kırmızı elbiseli — kart: ob2Video, seçilince: onb3RedSelected
    case second // siyahlı — kart: ob2Video2, seçilince: onb4Video

    /// Seçim kartında oynayan döngü videosu (uzantısız).
    var cardVideo: String {
        switch self {
        case .red: return "ob2Video"
        case .second: return "ob2Video2"
        }
    }

    /// Seçildikten sonra tam ekran oynayan video (uzantısız).
    var selectedVideo: String {
        switch self {
        case .red: return "onb3RedSelected"
        case .second: return "onb4Video"
        }
    }

    /// Onboarding sonunda doğrudan chat'ine girilecek backend karakterinin adı.
    var chatCharacterName: String {
        switch self {
        case .red: return "Scarlet"
        case .second: return "Maya"
        }
    }
}

@Observable
final class OnboardingStore {
    /// Onboarding tamamlandı mı — kalıcı.
    var isCompleted: Bool {
        didSet { defaults.set(isCompleted, forKey: Keys.completed) }
    }

    /// Kullanıcının girdiği isim — kalıcı.
    var userName: String {
        didSet { defaults.set(userName, forKey: Keys.userName) }
    }

    /// ONB3'te seçilen karakter — kalıcı (rawValue olarak).
    var selectedCharacter: OnboardingCharacter? {
        didSet { defaults.set(selectedCharacter?.rawValue, forKey: Keys.character) }
    }

    /// ONB4 soru cevapları (şık indeksleri, 0 tabanlı) — kalıcı.
    var answers: [Int] {
        didSet { defaults.set(answers, forKey: Keys.answers) }
    }

    /// Akışın mevcut adımı — kalıcı DEĞİL (her açılışta baştan).
    var step: OnboardingStep = .name

    /// Onboarding biter bitmez doğrudan açılacak chat karakterinin adı
    /// (ONB5'te set edilir, MainTabView görününce tüketilir). Kalıcı değil.
    var pendingChatCharacterName: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCompleted = defaults.bool(forKey: Keys.completed)
        userName = defaults.string(forKey: Keys.userName) ?? ""
        selectedCharacter = defaults.string(forKey: Keys.character).flatMap(OnboardingCharacter.init)
        answers = defaults.array(forKey: Keys.answers) as? [Int] ?? []

        #if DEBUG
        // Geliştirme kolaylığı: belirli bir onboarding adımını doğrudan açmak
        // için launch env değişkeni (ör. simülatörde ekran doğrulaması).
        //   SIMCTL_CHILD_OB_START_STEP=socialProof xcrun simctl launch ...
        if let forced = ProcessInfo.processInfo.environment["OB_START_STEP"] {
            switch forced {
            case "name":            step = .name
            case "socialProof":     step = .socialProof
            case "characterSelect": step = .characterSelect
            case "questions":       step = .questions
            case "finalTease":      step = .finalTease
            case "paywall":         step = .paywall
            default:                break
            }
        }
        #endif
    }

    func complete() {
        isCompleted = true
    }

    private enum Keys {
        static let completed = "onboarding.completed.v1"
        static let userName  = "onboarding.userName"
        static let character = "onboarding.selectedCharacter"
        static let answers   = "onboarding.answers"
    }
}

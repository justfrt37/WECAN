//
//  ConversationLanguage.swift
//  Bir sohbetin GERÇEKTE hangi dilde geçtiğini tahmin eder — cihazın sistem
//  diliyle karışmasın diye ayrı tutulur (örn. cihaz İngilizce ama kullanıcı
//  botla Türkçe konuşuyor olabilir; chat/index.ts'deki DİL KURALI kullanıcının
//  yazdığı dile geçer, sabit değildir). Bildirim içeriği (JealousyContent vb.)
//  hangi dil tablosunu kullanacağını buradan öğrenir.
//
//  Yalnızca elimizde el yazımı içerik tablosu olan diller arasında karar
//  verir — cihaz üzerinde (ağ yok) Apple'ın NaturalLanguage çerçevesiyle.
//  Uygulamanın UI dil desteğiyle (Localizable.xcstrings: en/tr/de/es/fr/it/pt)
//  eşleşecek şekilde 7 dile genişletildi (2026-07-09) — bkz. GhostedContent/
//  JealousyContent/SleepyContent/RoleOnlyContent/MissedYouContent/
//  GoodMorningContent, hepsi bu 7 dili kapsıyor.
//

import Foundation
import NaturalLanguage

enum ConversationLanguage {
    /// Desteklenen içerik dilleri — uygulamanın UI dil desteğiyle birebir.
    static let supported: Set<String> = ["tr", "en", "de", "es", "fr", "it", "pt"]

    /// Verilen metnin baskın dilini tahmin eder (ör. "tr", "en", "de"...).
    /// Metin çok kısaysa veya güvenilir bir sonuç yoksa nil döner.
    static func detect(from text: String) -> String? {
        guard text.count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// Bir sohbetin en güncel bildirim-dili tahmini: son bot mesajından
    /// algılanan dil desteklenen dillerden biriyse onu kullanır; değilse
    /// (algılama başarısız oldu ya da desteklenmeyen bir dilse) daha önce
    /// kaydedilmiş tahmine, o da yoksa cihazın sistem diline düşer.
    static func resolve(latestAssistantText: String?, previouslyDetected: String?) -> String {
        if let text = latestAssistantText, let detected = detect(from: text), supported.contains(detected) {
            return detected
        }
        if let previouslyDetected, supported.contains(previouslyDetected) {
            return previouslyDetected
        }
        let deviceCode = Locale.current.language.languageCode?.identifier ?? "en"
        return supported.contains(deviceCode) ? deviceCode : "en"
    }

    /// Bildirim dokunuşu anında bir karakter için kullanılacak dil — kayıtlı
    /// tahmin varsa onu kullanır, hiç sohbet yoksa (ör. "Liked You" — henüz
    /// konuşulmamış bot) cihaz diline düşer.
    static func current(for characterID: UUID) -> String {
        if let stored = LocalConversationStore.shared.load(for: characterID)?.detectedLanguage,
           supported.contains(stored) {
            return stored
        }
        return resolve(latestAssistantText: nil, previouslyDetected: nil)
    }
}

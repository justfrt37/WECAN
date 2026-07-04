//
//  VoiceLanguage.swift
//  Bir bot cevabının GERÇEKTE hangi dilde olduğunu tahmin eder — SADECE
//  sesli mesaj (TTS) özelliği için. `ConversationLanguage` (bildirim
//  içeriği için tr/en'e kilitli) ile KARIŞTIRILMASIN — o dosyaya dokunmuyoruz,
//  çünkü onun `supported` kümesini genişletmek bildirim içerik tablolarını
//  (JealousyContent vb., sadece tr/en'de var) bozar.
//

import Foundation
import NaturalLanguage

enum VoiceLanguage {
    /// Sesli mesaj için desteklenen 7 dil.
    static let supported: [String] = ["tr", "en", "de", "fr", "es", "pt", "it"]

    /// Verilen metnin baskın dilini tahmin eder, desteklenen 7 dilden biri
    /// değilse veya tahmin güvenilir değilse "en"'e düşer.
    static func detect(from text: String) -> String {
        guard text.count >= 4 else { return "en" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 7)
        for (language, _) in hypotheses.sorted(by: { $0.value > $1.value }) {
            if supported.contains(language.rawValue) { return language.rawValue }
        }
        return "en"
    }
}

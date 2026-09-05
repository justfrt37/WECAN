//
//  PhotoAccompanyContent.swift
//  "Send me a photo" düğmesine basınca botun sohbete düştüğü kısa eşlik
//  mesajı — foto kutusundan HEMEN ÖNCE ("bi saniye…") ya da foto açıldıktan
//  SONRA ("işte 😊"), ikisi birden DEĞİL. AI ile üretilmez (gecikme +
//  tutarsızlık): sabit havuzdan rastgele seçilir, FirstHelloContent gibi.
//
//  Satırlar KASITLI olarak fotoğrafın İÇERİĞİ hakkında hiçbir şey söylemez
//  (ışık, poz, mekân vb.) — yoksa küratörlü havuzdan gelen gerçek fotoyla
//  çelişebilir. Sadece "hazırlanıyorum / gönderdim" hissi verir.
//

import Foundation

enum PhotoAccompanyContent {
    /// Foto kutusundan ÖNCE gönderilir.
    private static let before: [String: [String]] = [
        "en": [
            "wait a sec…",
            "hold on, getting into position",
            "ok gimme a moment",
            "one sec, almost ready",
            "hang on lol",
            "let me just… ok",
            "gimme a second here",
            "ok hold on hold on",
            "wait, fixing my hair first",
            "two seconds",
            "ok almost… there",
            "hold that thought",
            "brb, setting this up",
            "ok ready in a sec",
            "just a moment 🙈",
        ],
        "tr": [
            "bi saniye…",
            "dur, poz veriyorum",
            "tamam bi dakika ver",
            "bi saniye, neredeyse hazır",
            "dur ya haha",
            "şunu bi… tamam",
            "bi saniye izin ver",
            "tamam dur dur",
            "dur saçımı düzelteyim önce",
            "iki saniye",
            "tamam neredeyse… oldu",
            "bekle bi saniye",
            "hemen ayarlıyorum",
            "tamam birazdan hazır",
            "bi dakika 🙈",
        ],
    ]

    /// Foto açıldıktan SONRA gönderilir.
    private static let after: [String: [String]] = [
        "en": [
            "there 😊",
            "ok, sent",
            "hope you like it",
            "that ok?",
            "took me long enough lol",
            "ta-da",
            "there you go",
            "sooo?",
        ],
        "tr": [
            "işte 😊",
            "tamam, gönderdim",
            "beğenirsin umarım",
            "oldu mu?",
            "baya uğraştım haha",
            "ta-da",
            "buyur bakalım",
            "eee nasıl?",
        ],
    ]

    /// Rastgele bir eşlik mesajı + fotoğrafa göre konumu. `before == true` ise
    /// kutudan önce, değilse foto açıldıktan sonra gönderilmeli.
    static func random() -> (text: String, before: Bool) {
        let lang = AppLanguage.supported.contains(AppLanguage.uiCode) ? AppLanguage.uiCode : "en"
        let before = Bool.random()
        let table = before ? Self.before : Self.after
        let pool = table[lang] ?? table["en"]!
        return (pool.randomElement()!, before)
    }
}

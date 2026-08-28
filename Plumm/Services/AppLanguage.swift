//
//  AppLanguage.swift
//  Plumm
//
//  UI ve DB-alanı çevirisi (tagline/profession/interests) için TEK doğruluk
//  kaynağı. Proje sadece en+tr'yi tam destekler (`Localizable.xcstrings`,
//  `project.pbxproj` knownRegions = en/tr/Base) — bu yüzden cihaz dili bu
//  ikisine sıkıştırılır: örn. Almanca bir cihaz İngilizce UI görür, o zaman
//  `tagline_i18n["de"]` de OKUNMAMALI (aksi halde İngilizce arayüz içinde
//  Almanca tagline gibi tutarsız bir karışım çıkar).
//
//  Sohbetin/sesli aramanın hangi dilde geçtiği bundan TAMAMEN ayrı —
//  bkz. ConversationLanguage (kullanıcının yazdığı metinden tespit eder).
//

import Foundation

enum AppLanguage {
    /// Bugün desteklenen tek iki UI dili.
    static let supported: Set<String> = ["en", "tr"]

    /// Cihazın dili desteklenenlerden biriyse onu, değilse İngilizceyi döner.
    /// `Character.localizedTagline` / `localizedProfession` / `localizedInterests`
    /// hepsi bunu kullanır.
    static var uiCode: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return supported.contains(code) ? code : "en"
    }
}

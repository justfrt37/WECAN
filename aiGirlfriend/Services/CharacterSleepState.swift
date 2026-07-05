//
//  CharacterSleepState.swift
//  Tek doğru kaynak: bir karakter şu an GERÇEKTEN uyuyor mu — programa göre
//  mi, yoksa uyandırma/erken-uyuma override'ları mı geçerli. Bkz.
//  LocalConversationStore.Stored.wokenUpAt/manualSleepAt.
//
//  Override'lar SESSION-BOUND: sadece İÇİNDE bulunduğumuz uyku bloğu
//  sırasında kaydedilmişlerse geçerli sayılır. Aksi halde ÖNCEKİ gecenin
//  override'ı (hiç temizlenmemiş olabilir — bkz. final review 2026-07-05)
//  bu gecenin uyku döngüsüne sızar: manualSleepAt sonsuza dek "uyuyor"
//  gösterirdi, wokenUpAt sonsuza dek "uyanık" gösterirdi.
//

import Foundation

enum CharacterSleepState {
    static func isEffectivelyAsleep(stored: LocalConversationStore.Stored?, now: Date = Date()) -> Bool {
        guard let stored else { return false } // hiç konuşulmamış — program henüz alakasız
        guard let schedule = stored.schedule,
              let block = ScheduleLookup.currentBlock(schedule: schedule, date: now) else { return false }

        if !block.isSleep {
            // Program zaten "uyanık" diyor — önceki bir uyku seansından kalma
            // override varsa bile anlamsız, hiçbir şeyi override etmiyor.
            return false
        }

        // Şu an gerçek bir uyku bloğunun İÇİNDEYİZ. Override'ı sadece BU
        // seans sırasında kaydedilmişse say — değilse önceki gecenin
        // kalıntısıdır, göz ardı et.
        let sessionStart = currentBlockStart(block: block, now: now)
        if let wokenUpAt = stored.wokenUpAt, wokenUpAt >= sessionStart { return false }
        if let manualSleepAt = stored.manualSleepAt, manualSleepAt >= sessionStart { return true }
        return true // gerçekten uyuyor, bu seans için geçerli bir override yok
    }

    /// `now`'ın içinde bulunduğu uyku bloğunun somut başlangıç anı — gece
    /// yarısını geçen bloklarda (ör. 23:00-07:00, `now` saat 02:00 iken)
    /// blok DÜN başlamış demektir.
    private static func currentBlockStart(block: ScheduleBlock, now: Date, calendar: Calendar = .current) -> Date {
        let parts = block.start.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2,
              let todayStart = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now)
        else { return now }
        // Bugünün başlangıç saati hâlâ `now`'dan İLERİDEYSE, içinde olduğumuz
        // blok aslında DÜN başlamış demektir (gece yarısı sarması).
        return todayStart > now ? (calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart) : todayStart
    }
}

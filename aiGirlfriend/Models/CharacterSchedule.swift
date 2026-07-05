//
//  CharacterSchedule.swift
//  Bir (kullanıcı, karakter) sohbetine özel günlük rutin — mesleğe/kişiliğe
//  göre üretilir, sohbetteki gerçeklere göre zamanla güncellenir (bkz.
//  ChatViewModel.ensureScheduleGenerated / triggerSummarizationIfNeeded).
//

import Foundation

struct ScheduleBlock: Codable, Equatable {
    /// "HH:mm", 24 saat, cihazın yerel saatine göre. `end < start` ise gece
    /// yarısını geçen bir blok demektir (ör. start "23:00", end "07:00").
    let start: String
    let end: String
    /// Kısa, chat header'da gösterilecek — "At work".
    let label: String
    /// Daha ayrıntılı, sistem promptuna eklenecek — "at work in the lab
    /// running experiments".
    let detail: String
}

struct CharacterSchedule: Codable, Equatable {
    let weekday: [ScheduleBlock]
    let weekend: [ScheduleBlock]
}

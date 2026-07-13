//
//  ScheduleLookup.swift
//  Verilen bir CharacterSchedule ve zamana göre "şu an ne yapıyor" bloğunu
//  bulur — saf/durumsuz, ağ çağrısı yok, her ChatView render'ında ucuza
//  çağrılabilir.
//

import Foundation

enum ScheduleLookup {
    static func currentBlock(
        schedule: CharacterSchedule,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduleBlock? {
        let blocks = calendar.isDateInWeekend(date) ? schedule.weekend : schedule.weekday
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = comps.hour, let minute = comps.minute else { return nil }
        let nowMinutes = hour * 60 + minute

        for block in blocks {
            guard let startMinutes = minutesFromHHmm(block.start),
                  let endMinutes = minutesFromHHmm(block.end) else { continue }
            if startMinutes <= endMinutes {
                if nowMinutes >= startMinutes && nowMinutes < endMinutes { return block }
            } else {
                // Gece yarısını geçen blok (ör. 23:00-07:00).
                if nowMinutes >= startMinutes || nowMinutes < endMinutes { return block }
            }
        }
        return nil
    }

    /// Karakterin GERÇEK programına göre bir sonraki uyku bloğunun başlangıç
    /// anı — bugün henüz gelmediyse bugün, geldiyse (ya da yoksa) ileriki
    /// günlere bakar (en fazla bir hafta ileri, sonsuz döngüye girmesin diye).
    /// Bkz. NotificationScheduler.rescheduleBedtime.
    static func nextSleepBlockStart(
        schedule: CharacterSchedule,
        from: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        for dayOffset in 0..<8 {
            guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: from) else { continue }
            let blocks = calendar.isDateInWeekend(candidateDay) ? schedule.weekend : schedule.weekday
            let starts: [Date] = blocks.compactMap { block -> Date? in
                guard block.isSleep, let startMinutes = minutesFromHHmm(block.start) else { return nil }
                return calendar.date(
                    bySettingHour: startMinutes / 60, minute: startMinutes % 60, second: 0, of: candidateDay
                )
            }.filter { $0 > from }
            if let earliest = starts.min() { return earliest }
        }
        return nil
    }

    /// Karakterin GERÇEK programına göre uyanma anı — bugünkü sabah uyku
    /// bloğunun bitişi (öğlenden önce biten ilk uyku bloğu), bugün geçmiş
    /// olsa bile döner (Good Morning bildirimi bunu "bugünkü uyanma + offset"
    /// hesabı için kullanır — bkz. NotificationScheduler.rescheduleGoodMorning).
    /// Bugün uygun bir blok yoksa (nadir), nextSleepBlockStart'la aynı
    /// güvenlik ağıyla ileriki günlere bakar.
    static func nextWakeTime(
        schedule: CharacterSchedule,
        from: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        for dayOffset in 0..<8 {
            guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: from) else { continue }
            let blocks = calendar.isDateInWeekend(candidateDay) ? schedule.weekend : schedule.weekday
            let wakeTimes: [Date] = blocks.compactMap { block -> Date? in
                guard block.isSleep, let endMinutes = minutesFromHHmm(block.end), endMinutes < 12 * 60 else { return nil }
                return calendar.date(
                    bySettingHour: endMinutes / 60, minute: endMinutes % 60, second: 0, of: candidateDay
                )
            }
            let candidates = dayOffset == 0 ? wakeTimes : wakeTimes.filter { $0 > from }
            if let earliest = candidates.min() { return earliest }
        }
        return nil
    }

    private static func minutesFromHHmm(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

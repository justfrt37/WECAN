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

    private static func minutesFromHHmm(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

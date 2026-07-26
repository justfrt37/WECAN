//
//  RelationshipXP.swift
//  DEPRECATED (2026-07): İlişki seviyesi/terfi hesabı yeniden SUNUCUYA taşındı
//  (bkz. supabase/functions/chat/index.ts — gainPercent/perMessageFraction/
//  applyRelationshipGain). Bu dosya artık çağrılmıyor; eğri referansı olarak
//  duruyor (sunucudaki TS portu bununla birebir aynı). Silinebilir.
//
//  Model: XP artık kümülatif bir sayı değil, "şu anki seviyenin ne kadarı
//  tamamlandı" (0...1) şeklinde bir ORAN. Her mesaj-batch'i (5 mesajda bir) veya
//  foto gönderimi, seviyenin gerektirdiği ilerlemenin bir YÜZDESİNİ ekler.
//  Lv 1-3 hızlı terfi eder (ilk bağ kurulumu kolay olsun diye): %33/%25/%18/tık
//  (~15/20/28 mesaj). Lv 4+ eskisi gibi düz azalan eğriyle zorlaşır:
//    Lv 5: %7, Lv 7: %5, ... (konveks, düşük tabanı %1).
//

import Foundation

enum RelationshipXP {
    static let maxLevel = 10
    static let messageBatchSize = 5   // her 5 mesajda bir kazanım tıklaması
    static let photoGainMultiplier = 1.5   // foto, normal tıktan %50 daha değerli (eski 30/20 oranı)

    /// Bu seviyedeyken bir "kazanım tık"ının seviye ilerlemesine kattığı yüzde (0...100).
    /// Lv1-3 hızlı: %33/%25/%18 (ilk bağ kurulumu kolay olsun diye). Lv4+ için
    /// düz azalan eğri: p(x) = -0.125x² + 8.125, x = level-2 — bu eğri (3,8) (5,7)
    /// (7,5) noktalarından tam geçer; terfi üst seviyelerde giderek zorlaşsın diye
    /// kasıtlı olarak konveks (ivmeli) azalıyor.
    static func gainPercent(forLevel level: Int) -> Double {
        switch level {
        case ...1: return 33   // ~15 mesaj/seviye
        case 2:    return 25   // ~20 mesaj/seviye
        case 3:    return 18   // ~28 mesaj/seviye
        default:
            let x = Double(level - 2)
            let raw = -0.125 * x * x + 8.125
            return max(1, raw)   // en tepede bile tamamen tıkanmasın diye %1 taban
        }
    }

    static func messageGainFraction(forLevel level: Int) -> Double {
        gainPercent(forLevel: level) / 100
    }

    static func photoGainFraction(forLevel level: Int) -> Double {
        messageGainFraction(forLevel: level) * photoGainMultiplier
    }

    /// Yeni seviye + kalan ilerleme oranını hesaplar (birden fazla seviye atlamayı da destekler).
    static func applyGain(_ fraction: Double, level: Int, progress: Double) -> (level: Int, progress: Double) {
        guard level < maxLevel else { return (maxLevel, 0) }
        var lvl = level
        var prog = progress + fraction
        while prog >= 1, lvl < maxLevel {
            prog -= 1
            lvl += 1
        }
        if lvl >= maxLevel { return (maxLevel, 0) }
        return (lvl, prog)
    }
}

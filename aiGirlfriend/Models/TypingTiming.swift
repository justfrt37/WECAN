//
//  TypingTiming.swift
//  Botun "yazıyor..." balonunun ne kadar açık kalacağını hesaplar — mesaj
//  uzunluğuna göre değişir ama TAM gerçekçi değildir (uzun mesajlarda saniyelerce
//  beklemek can sıkıcı olur), bu yüzden üst sınırla sıkıştırılır.
//

import Foundation

enum TypingTiming {
    /// Botun saniyede "yazdığı" karakter sayısı.
    private static let botCharsPerSecond: Double = 30
    /// Üst sınır — ~200 karakterlik bir cevapta (200/30 ≈ 6.7s) tam bu noktada devreye girer.
    private static let maxDuration: TimeInterval = 6.7

    /// Balonun mesaj gönderilmeden önce (kullanıcı gönder'e bastıktan sonra) belirip
    /// belirmeyeceğine dair rastgele başlangıç gecikmesi — her seferinde farklı.
    static func randomStartDelay() -> TimeInterval { .random(in: 0.5...1.0) }

    /// Cevap uzunluğuna göre balonun ekranda kalması gereken süre. 0.6-6.7s
    /// arasında sıkıştırılır: kısa cevaplar hızlı gelsin, uzun cevaplar biraz
    /// daha beklesin ama gerçek yazma süresi kadar uzamasın.
    static func duration(forReplyLength length: Int) -> TimeInterval {
        guard length > 0 else { return 0 }
        let raw = Double(length) / botCharsPerSecond
        return min(max(raw, 0.6), maxDuration)
    }
}

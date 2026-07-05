//
//  AppearanceOptions.swift
//  Karakter yaratma sihirbazındaki görünüm adımları (saç stili/rengi, göz şekli/
//  rengi, burun şekli, ten tonu) için seçenek listeleri + FacePreview'ün
//  kullandığı renk eşlemeleri.
//

import SwiftUI

enum AppearanceOptions {
    static let hairstyles = ["Straight", "Wavy", "Curly", "Ponytail", "Bun", "Pixie",
                              "Braided", "Bob", "Long Layers", "Undercut"]
    static let hairColors = ["Black", "Brown", "Blonde", "Red", "Auburn", "Pink",
                              "Silver", "Blue", "Copper", "Purple"]
    static let eyeShapes = ["Almond", "Round", "Hooded", "Monolid",
                             "Upturned", "Downturned", "Deep-set", "Wide-set"]
    static let eyeColors = ["Brown", "Blue", "Green", "Hazel", "Gray", "Amber",
                             "Turquoise", "Violet", "Emerald", "Steel Blue"]
    static let noseShapes = ["Straight", "Button", "Aquiline", "Wide",
                              "Roman", "Snub", "Nubian", "Greek"]
    // Ten tonu — app içindeki görsellerle eşleşen set.
    static let skinTones = ["Porcelain", "Fair", "Tan", "Deep", "Golden", "Caramel"]
    // Etnik köken (değer=İngilizce prompt için, gösterim=Türkçe). Görseller: "Etnik Köken" klasörü.
    static let ethnicities = ["African", "Mediterranean", "European", "East Asian",
                               "South Asian", "Southeast Asian", "Scandinavian",
                               "North African", "Latina", "Middle Eastern", "Slavic", "Mixed"]
    static let ageRanges = ["18-21", "22-27", "28-35", "36-42", "43-52", "53-65", "65+"]

    /// Değer (İngilizce) → Türkçe gösterim adı. Bilinmeyen değeri aynen döndürür.
    static func tr(_ v: String) -> String { trMap[v] ?? v }

    private static let trMap: [String: String] = [
        // Kategori
        "Realistic": "Gerçekçi", "Anime": "Anime", "Fictional": "Kurgusal", "Fantasy": "Fantezi", "Sci-Fi": "Bilim Kurgu",
        // Tarz
        "Sweet": "Tatlı", "Mysterious": "Gizemli", "Energetic": "Enerjik", "Elegant": "Zarif",
        // Saç stili
        "Straight": "Düz", "Wavy": "Dalgalı", "Curly": "Kıvırcık", "Ponytail": "At Kuyruğu",
        "Bun": "Topuz", "Pixie": "Pixie Kesim", "Braided": "Örgülü", "Bob": "Bob Kesim",
        "Long Layers": "Uzun Katlı", "Undercut": "Undercut",
        // Saç rengi
        "Black": "Siyah", "Brown": "Kahverengi", "Blonde": "Sarışın", "Red": "Kızıl",
        "Auburn": "Kestane Kızılı", "Pink": "Pembe", "Silver": "Gümüş", "Blue": "Mavi",
        "Copper": "Bakır", "Purple": "Mor",
        // Göz rengi (Brown/Blue/Pink çakışmaları saç ile aynı Türkçe — sorun değil)
        "Green": "Yeşil", "Hazel": "Ela", "Gray": "Gri", "Amber": "Amber",
        "Turquoise": "Turkuaz", "Violet": "Menekşe", "Emerald": "Zümrüt", "Steel Blue": "Çelik Mavisi",
        // Ten tonu
        "Porcelain": "Porselen", "Fair": "Açık", "Light": "Açık Ton", "Medium": "Orta",
        "Tan": "Bronz", "Deep": "Koyu", "Ivory": "Fildişi", "Golden": "Altın Ton",
        "Caramel": "Karamel", "Ebony": "Abanoz",
        // Etnik köken
        "African": "Afrikalı", "Mediterranean": "Akdeniz", "European": "Avrupalı",
        "East Asian": "Doğu Asya", "South Asian": "Güney Asya", "Southeast Asian": "Güneydoğu Asya",
        "Scandinavian": "İskandinav", "Mixed": "Karışık", "North African": "Kuzey Afrikalı",
        "Latina": "Latin", "Middle Eastern": "Orta Doğu", "Slavic": "Slav",
    ]

    static func hairColorValue(_ name: String) -> Color {
        switch name {
        case "Black":    return Color(hex: 0x1C1B1A)
        case "Brown":    return Color(hex: 0x5C3A21)
        case "Blonde":   return Color(hex: 0xE8C77E)
        case "Red":      return Color(hex: 0xA33F1F)
        case "Auburn":   return Color(hex: 0x7B3F2A)
        case "Pink":     return Color(hex: 0xE79ACB)
        case "Silver":   return Color(hex: 0xC7CBD1)
        case "Blue":     return Color(hex: 0x4E7FB5)
        case "Chestnut": return Color(hex: 0x6B3A2E)
        case "Platinum": return Color(hex: 0xEDEAE3)
        case "Copper":   return Color(hex: 0xB5622A)
        case "Purple":   return Color(hex: 0x7C5AA6)
        default:         return .gray
        }
    }

    static func eyeColorValue(_ name: String) -> Color {
        switch name {
        case "Brown":      return Color(hex: 0x6B4226)
        case "Blue":       return Color(hex: 0x3C7DC4)
        case "Green":      return Color(hex: 0x4C8C4A)
        case "Hazel":      return Color(hex: 0x8C7A4B)
        case "Gray":       return Color(hex: 0x9AA0A6)
        case "Amber":      return Color(hex: 0xC98A2C)
        case "Turquoise":  return Color(hex: 0x3FB6A8)
        case "Violet":     return Color(hex: 0x8B5FBF)
        case "Emerald":    return Color(hex: 0x2E8B6F)
        case "Steel Blue": return Color(hex: 0x4A6D8C)
        default:           return .gray
        }
    }

    static func skinToneValue(_ name: String) -> Color {
        switch name {
        case "Porcelain": return Color(hex: 0xF6E1D3)
        case "Fair":      return Color(hex: 0xEFC9A8)
        case "Light":     return Color(hex: 0xE0AC80)
        case "Medium":    return Color(hex: 0xC38A5F)
        case "Tan":       return Color(hex: 0x9C6B44)
        case "Deep":      return Color(hex: 0x5A3A22)
        case "Ivory":     return Color(hex: 0xFBEBDD)
        case "Golden":    return Color(hex: 0xD9A066)
        case "Caramel":   return Color(hex: 0xA8703F)
        case "Ebony":     return Color(hex: 0x3B2415)
        default:          return .gray
        }
    }
}

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
                              "Silver", "Blue", "Chestnut", "Platinum", "Copper", "Purple"]
    static let eyeShapes = ["Almond", "Round", "Hooded", "Monolid",
                             "Upturned", "Downturned", "Deep-set", "Wide-set"]
    static let eyeColors = ["Brown", "Blue", "Green", "Hazel", "Gray", "Amber",
                             "Turquoise", "Violet", "Olive", "Steel Blue"]
    static let noseShapes = ["Straight", "Button", "Aquiline", "Wide",
                              "Roman", "Snub", "Nubian", "Greek"]
    // Nötr bir ton skalası — etnisite değil, sadece açık-koyu spektrumu.
    static let skinTones = ["Porcelain", "Fair", "Light", "Medium", "Tan", "Deep",
                             "Ivory", "Golden", "Caramel", "Ebony"]

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
        case "Olive":      return Color(hex: 0x76812F)
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

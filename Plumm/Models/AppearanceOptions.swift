//
//  AppearanceOptions.swift
//  Karakter yaratma sihirbazındaki görünüm adımları (saç stili/rengi, göz şekli/
//  rengi, burun şekli, ten tonu) için seçenek listeleri. Önizleme görselleri
//  Assets.xcassets'ten gelir (bkz. FacePreview).
//

import Foundation

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
    // Vücut tipi — görsel üretim promptuna gider (bkz. chat-image/appearanceContext,
    // create-character/buildImagePrompt), önizleme görseli yok (metin chip).
    static let bodyTypes = ["Slim", "Athletic", "Curvy", "Average", "Voluptuous", "Plus Size"]
    // Etnik köken — değer İngilizce prompt/DB için, gösterim de aynı stringden
    // Localizable.xcstrings üzerinden (bkz. CreateCharacterView.imageOptionCard
    // / textOptionCard: Text(LocalizedStringKey(value))). Görseller: "Etnik Köken" klasörü.
    static let ethnicities = ["African", "Mediterranean", "European", "East Asian",
                               "South Asian", "Southeast Asian", "Scandinavian",
                               "North African", "Latina", "Middle Eastern", "Slavic", "Mixed"]
    static let ageRanges = ["18-21", "22-27", "28-35", "36-42", "43-52", "53-65", "65+"]
}

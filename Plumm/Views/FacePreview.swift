//
//  FacePreview.swift
//  Karakter yaratma sihirbazındaki görünüm adımları için önizleme — AI ile
//  üretilmiş, tek seferlik bir toplu üretimden gelen küçük yüz görselleri
//  (bkz. Assets.xcassets, "hairstyle_/haircolor_/eyeshape_/eyecolor_/
//  noseshape_/skintone_" ön ekli imageset'ler). Her kart SADECE o an karar
//  verilen özelliği gösterir — diğer özellikler nötr/varsayılan kalır, çünkü
//  her görsel zaten sabit bir taban yüze göre üretildi (bkz. görsel üretim
//  promptları — sadece hedeflenen özellik değişti, geri kalanı sabit tutuldu).
//

import SwiftUI

struct FacePreview: View {
    enum Feature { case hairstyle, hairColor, eyeShape, eyeColor, noseShape, skinTone }

    let highlight: Feature
    var hairstyle: String = AppearanceOptions.hairstyles[0]
    var hairColor: String = AppearanceOptions.hairColors[0]
    var eyeShape: String = AppearanceOptions.eyeShapes[0]
    var eyeColor: String = AppearanceOptions.eyeColors[0]
    var noseShape: String = AppearanceOptions.noseShapes[0]
    var skinTone: String = AppearanceOptions.skinTones[0]

    var body: some View {
        Image(assetName)
            .resizable()
            .scaledToFill()
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private var assetName: String {
        switch highlight {
        case .hairstyle: return Self.name(prefix: "hairstyle", value: hairstyle)
        case .hairColor: return Self.name(prefix: "haircolor", value: hairColor)
        case .eyeShape:  return Self.name(prefix: "eyeshape", value: eyeShape)
        case .eyeColor:  return Self.name(prefix: "eyecolor", value: eyeColor)
        case .noseShape: return Self.name(prefix: "noseshape", value: noseShape)
        case .skinTone:  return Self.name(prefix: "skintone", value: skinTone)
        }
    }

    private static func name(prefix: String, value: String) -> String {
        let safe = value.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        return "\(prefix)_\(safe)"
    }
}

#Preview {
    HStack {
        FacePreview(highlight: .hairstyle, hairstyle: "Curly")
        FacePreview(highlight: .eyeColor, eyeColor: "Green")
        FacePreview(highlight: .skinTone, skinTone: "Tan")
    }
    .frame(height: 80)
    .padding()
    .background(Color.black)
}

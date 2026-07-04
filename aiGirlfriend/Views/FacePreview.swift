//
//  FacePreview.swift
//  Karakter yaratma sihirbazındaki görünüm adımları için SwiftUI Shape/Path ile
//  çizilmiş bir yüz önizlemesi. Sadece o an seçilmekte olan özellik (saç stili/
//  rengi, göz şekli/rengi, burun şekli, ten tonu) gerçek renk/şekille çizilir —
//  geri kalan her şey nötr, dolgusuz bir taslak olarak kalır (kullanıcı o an
//  SADECE o seçimi görsün, biriken tam bir yüz değil).
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

    private let neutral = Color.white.opacity(0.4)
    private let neutralFill = Color.white.opacity(0.05)

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                // Kafa — hafif oval, gerçekçi yüz oranına yakın.
                let headFill: AnyShapeStyle = highlight == .skinTone
                    ? AnyShapeStyle(RadialGradient(
                        colors: [AppearanceOptions.skinToneValue(skinTone).opacity(0.95),
                                 AppearanceOptions.skinToneValue(skinTone)],
                        center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.7))
                    : AnyShapeStyle(neutralFill)
                Ellipse()
                    .fill(headFill)
                    .overlay(Ellipse().stroke(neutral, lineWidth: 1.5))
                    .frame(width: size * 0.82, height: size * 0.92)

                // Saç — şekli SADECE hairstyle adımında değişir, rengi SADECE hairColor adımında dolar.
                let hairShape = HairShape(style: highlight == .hairstyle ? hairstyle : AppearanceOptions.hairstyles[0])
                let hairFill: AnyShapeStyle = highlight == .hairColor
                    ? AnyShapeStyle(LinearGradient(
                        colors: [AppearanceOptions.hairColorValue(hairColor),
                                 AppearanceOptions.hairColorValue(hairColor).opacity(0.75)],
                        startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Color.clear)
                hairShape
                    .fill(hairFill)
                    .overlay(hairShape.stroke(neutral, lineWidth: 1.2))
                    .frame(width: size * 0.92, height: size * 0.56)
                    .offset(y: -size * 0.26)

                // Gözler
                HStack(spacing: size * 0.15) {
                    eye(size: size)
                    eye(size: size)
                }
                .offset(y: -size * 0.02)

                // Burun
                NoseShape(style: highlight == .noseShape ? noseShape : AppearanceOptions.noseShapes[0])
                    .stroke(neutral, lineWidth: 1.3)
                    .frame(width: size * 0.16, height: size * 0.2)
                    .offset(y: size * 0.1)

                // Ağız — sabit, nötr; sadece yüzün "boş taslak" değil gerçek bir
                // yüz gibi okunması için.
                MouthShape()
                    .stroke(neutral, lineWidth: 1.3)
                    .frame(width: size * 0.22, height: size * 0.06)
                    .offset(y: size * 0.28)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func eye(size: CGFloat) -> some View {
        let shape = EyeShape(style: highlight == .eyeShape ? eyeShape : AppearanceOptions.eyeShapes[0])
        let fill: AnyShapeStyle = highlight == .eyeColor
            ? AnyShapeStyle(AppearanceOptions.eyeColorValue(eyeColor))
            : AnyShapeStyle(Color.clear)
        return ZStack {
            shape.fill(fill)
            shape.stroke(neutral, lineWidth: 1)
            if highlight == .eyeColor {
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: size * 0.05, height: size * 0.05)
            }
        }
        .frame(width: size * 0.2, height: size * 0.11)
    }
}

// MARK: - Şekiller

private struct HairShape: Shape {
    let style: String

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height

        switch style {
        case "Wavy":
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.3))
            p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.3),
                       control1: CGPoint(x: rect.minX + w * 0.3, y: rect.minY - h * 0.1),
                       control2: CGPoint(x: rect.minX + w * 0.7, y: rect.minY + h * 0.55))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.closeSubpath()
        case "Curly":
            let bumps = 5
            for i in 0..<bumps {
                let cx = rect.minX + w * (CGFloat(i) + 0.5) / CGFloat(bumps)
                p.addEllipse(in: CGRect(x: cx - w * 0.12, y: rect.minY, width: w * 0.24, height: h * 0.5))
            }
        case "Ponytail":
            p.addPath(Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: h * 0.55),
                            cornerRadius: h * 0.2))
            p.addEllipse(in: CGRect(x: rect.maxX - w * 0.1, y: rect.minY + h * 0.25, width: w * 0.16, height: h * 0.7))
        case "Bun":
            p.addPath(Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: h * 0.5),
                            cornerRadius: h * 0.2))
            p.addEllipse(in: CGRect(x: rect.midX - w * 0.16, y: rect.minY - h * 0.18, width: w * 0.32, height: w * 0.32))
        case "Pixie":
            p.addPath(Path(roundedRect: CGRect(x: rect.minX + w * 0.12, y: rect.minY, width: w * 0.76, height: h * 0.35),
                            cornerRadius: h * 0.16))
        case "Braided":
            let segments = 4
            let segW = w * 0.5
            for i in 0..<segments {
                let cy = rect.minY + h * 0.15 + h * 0.16 * CGFloat(i)
                let inset = (i % 2 == 0) ? 0.0 : w * 0.08
                p.addEllipse(in: CGRect(x: rect.midX - segW / 2 + inset, y: cy, width: segW - inset, height: h * 0.16))
            }
        case "Bob":
            p.addPath(Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: h * 0.7),
                            cornerRadius: h * 0.28))
        case "Long Layers":
            p.addPath(Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: h * 0.4),
                            cornerRadius: h * 0.2))
            p.addEllipse(in: CGRect(x: rect.minX + w * 0.02, y: rect.minY + h * 0.25, width: w * 0.22, height: h * 0.75))
            p.addEllipse(in: CGRect(x: rect.maxX - w * 0.24, y: rect.minY + h * 0.25, width: w * 0.22, height: h * 0.75))
        case "Undercut":
            p.addPath(Path(roundedRect: CGRect(x: rect.minX + w * 0.18, y: rect.minY, width: w * 0.64, height: h * 0.3),
                            cornerRadius: h * 0.14))
        default: // Straight
            p.addPath(Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: h * 0.6),
                            cornerRadius: h * 0.22))
        }
        return p
    }
}

private struct EyeShape: Shape {
    let style: String

    func path(in rect: CGRect) -> Path {
        switch style {
        case "Round":
            return Circle().path(in: rect)
        case "Hooded":
            return Ellipse().path(in: rect.insetBy(dx: 0, dy: rect.height * 0.12))
        case "Monolid":
            return Ellipse().path(in: rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.3))
        case "Upturned":
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.15),
                           control: CGPoint(x: rect.midX, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY),
                           control: CGPoint(x: rect.midX, y: rect.maxY))
            return p
        case "Downturned":
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                           control: CGPoint(x: rect.midX, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15),
                           control: CGPoint(x: rect.midX, y: rect.maxY))
            return p
        case "Deep-set":
            return Ellipse().path(in: rect.insetBy(dx: rect.width * 0.14, dy: rect.height * 0.08))
        case "Wide-set":
            return Ellipse().path(in: rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.2))
        default: // Almond
            return Ellipse().path(in: rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.15))
        }
    }
}

private struct NoseShape: Shape {
    let style: String

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch style {
        case "Button":
            p.addEllipse(in: CGRect(x: rect.midX - rect.width * 0.16, y: rect.maxY - rect.height * 0.32,
                                     width: rect.width * 0.32, height: rect.height * 0.32))
        case "Aquiline":
            p.move(to: CGPoint(x: rect.midX - rect.width * 0.05, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX + rect.width * 0.18, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        case "Wide":
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX - rect.width * 0.22, y: rect.maxY))
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX + rect.width * 0.22, y: rect.maxY))
        case "Roman":
            p.move(to: CGPoint(x: rect.midX - rect.width * 0.08, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                           control: CGPoint(x: rect.midX + rect.width * 0.22, y: rect.midY))
        case "Snub":
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.midX - rect.width * 0.06, y: rect.maxY),
                           control: CGPoint(x: rect.midX - rect.width * 0.18, y: rect.midY))
        case "Nubian":
            p.addPath(Path(roundedRect: CGRect(x: rect.midX - rect.width * 0.14, y: rect.midY,
                                                width: rect.width * 0.28, height: rect.height * 0.4),
                            cornerRadius: rect.width * 0.1))
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
        case "Greek":
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.move(to: CGPoint(x: rect.midX - rect.width * 0.12, y: rect.minY + rect.height * 0.1))
            p.addLine(to: CGPoint(x: rect.midX + rect.width * 0.12, y: rect.minY + rect.height * 0.1))
        default: // Straight
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
        return p
    }
}

private struct MouthShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.midX, y: rect.maxY))
        return p
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

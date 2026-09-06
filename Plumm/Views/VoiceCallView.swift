//
//  VoiceCallView.swift
//  Tam ekran sesli arama — avatar + durum göstergesi, altyazı yok (bkz. design spec).
//

import SwiftUI
import UIKit

/// ChatGPT sesli mod tarzı katmanlı, bulanık "aura" — durum metni yerine
/// karakterin dinlediğini/konuştuğunu görsel olarak anlatır (bkz. kullanıcı
/// talebi: "listening yazmak yerine ses ışıklandırması gibi bir şey").
/// Renk + hız duruma göre değişir; TimelineView(.animation) ile sürekli,
/// kesintisiz akar — durumlar arası geçişte animasyon yeniden BAŞLAMAZ,
/// sadece hedef renk/hız kayar (aksi halde her state değişiminde halka
/// sıfırlanıp "atlıyormuş" gibi görünürdü).
private struct VoiceAuraView: View {
    let state: CallState

    private var palette: [Color] {
        switch state {
        case .listening: return [Color(hex: 0x64D2FF), Color(hex: 0x9B8CFF)]
        case .thinking: return [Color(hex: 0xB98CFF), Color(hex: 0x64D2FF)]
        case .speaking: return [AppColor.pink, Color(hex: 0xFF8AD4)]
        default: return [AppColor.pink.opacity(0.5), AppColor.pink.opacity(0.5)]
        }
    }

    private var isActive: Bool {
        switch state {
        case .listening, .thinking, .speaking: return true
        default: return false
        }
    }

    /// Konuşurken en canlı/hızlı (kendi sesi), dinlerken sakin ve sürekli
    /// (seni dinlediğini hissettirmek için asla durağan görünmemeli),
    /// düşünürken ikisi arası.
    private var speed: Double {
        switch state {
        case .speaking: return 1.7
        case .thinking: return 1.15
        case .listening: return 0.85
        default: return 0.4
        }
    }

    var body: some View {
        TimelineView(.animation(paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * speed
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    let phase = Double(i) * 2.4
                    let wobble = sin(t + phase) * 0.5 + 0.5 // 0...1, sürekli nefes alıp veriyor
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [palette[i % palette.count].opacity(0.6), .clear],
                                center: .center, startRadius: 8, endRadius: 150
                            )
                        )
                        .frame(width: 230, height: 230)
                        .scaleEffect(1.0 + wobble * 0.24 + Double(i) * 0.1)
                        .opacity(isActive ? 0.5 + wobble * 0.4 : 0.22)
                        .blur(radius: 20)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: isActive)
        }
        .allowsHitTesting(false)
    }
}

/// Scale + fade on press, spring-back on release — used by every tappable
/// control on this screen so it reads as responsive (no built-in SwiftUI
/// Button gives any press feedback by default).
private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
    }
}

struct VoiceCallView: View {
    @State private var viewModel: CallViewModel
    @Environment(\.dismiss) private var dismiss
    let tokenStore: TokenStore
    @State private var typedText = ""
    @FocusState private var textFieldFocused: Bool
    @State private var chargeOpacity: Double = 0

    init(character: Character, conversationId: String?, tokenStore: TokenStore) {
        _viewModel = State(initialValue: CallViewModel(character: character, conversationId: conversationId))
        self.tokenStore = tokenStore
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1A0F1F), Color(hex: 0x2B1730)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                ZStack {
                    VoiceAuraView(state: viewModel.state)

                    CachedImage(url: viewModel.character.avatarURL ?? viewModel.character.photoURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { AppColor.pink }
                    .frame(width: 180, height: 180)
                    .clipShape(Circle())
                }

                Text(viewModel.character.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                // Dinliyor/düşünüyor/konuşuyor durumları artık metinle değil
                // VoiceAuraView'in kendisiyle anlatılıyor (bkz. kullanıcı talebi) —
                // metin sadece ışıklandırmanın karşılığı olmayan durumlarda kalır.
                if showsStatusText {
                    Text(statusLabel)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }

                if case .ended = viewModel.state {} else {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsedLabel)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }

                if let tokensCharged = viewModel.tokensCharged {
                    HStack(spacing: 4) {
                        Image("heartCoin").resizable().scaledToFit().frame(width: 14, height: 14)
                        Text("-\(tokensCharged)")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(AppColor.amber)
                    .opacity(chargeOpacity)
                    .onAppear { withAnimation(.easeOut(duration: 0.3)) { chargeOpacity = 1 } }
                }

                Spacer()

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 32)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 8) {
                    TextField("Type instead of speaking…", text: $typedText)
                        .focused($textFieldFocused)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                        .submitLabel(.send)
                        .onSubmit(sendTypedText)

                    Button(action: sendTypedText) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(typedText.trimmingCharacters(in: .whitespaces).isEmpty ? .white.opacity(0.3) : AppColor.pink)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(typedText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 24)

                HStack(spacing: 40) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        viewModel.toggleMute()
                    } label: {
                        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        Task {
                            await viewModel.endCall()
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(Color.red, in: Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            viewModel.tokenStore = tokenStore
            Task { await viewModel.startCall() }
        }
        .onChange(of: viewModel.state) { _, newState in
            if case .ended = newState {
                Task {
                    // Longer when there's a charge to show — give the "-N" fade-in
                    // time to actually be seen before the screen disappears.
                    let delay: UInt64 = viewModel.tokensCharged != nil ? 1_600_000_000 : 800_000_000
                    try? await Task.sleep(nanoseconds: delay)
                    dismiss()
                }
            }
        }
        .onDisappear {
            Task { await viewModel.endCall() }
        }
    }

    private func sendTypedText() {
        let text = typedText
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        typedText = ""
        textFieldFocused = false
        Task { await viewModel.sendTypedText(text) }
    }

    private var elapsedLabel: String {
        let total = Int(viewModel.elapsedSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// listening/thinking/speaking artık VoiceAuraView ile anlatılıyor —
    /// metin sadece ışıklandırmanın karşılık gelmediği durumlarda görünür.
    private var showsStatusText: Bool {
        switch viewModel.state {
        case .idle, .ended: return true
        case .listening, .thinking, .speaking: return false
        }
    }

    private var statusLabel: String {
        switch viewModel.state {
        case .idle: return String(localized: "Connecting…")
        case .listening: return String(localized: "Listening…")
        case .thinking: return String(localized: "Thinking…")
        case .speaking: return String(localized: "Speaking…")
        case .ended(let reason):
            switch reason {
            case .userEnded: return String(localized: "Call ended")
            case .insufficientTokens: return String(localized: "Out of tokens — call ended")
            case .notEntitled: return String(localized: "Voice calls require Pro+")
            case .error: return String(localized: "Call failed")
            }
        }
    }
}

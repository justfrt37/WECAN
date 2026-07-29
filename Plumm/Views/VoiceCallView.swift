//
//  VoiceCallView.swift
//  Tam ekran sesli arama — avatar + durum göstergesi, altyazı yok (bkz. design spec).
//

import SwiftUI

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
                    Circle()
                        .fill(AppColor.pink.opacity(0.25))
                        .frame(width: 220, height: 220)
                        .scaleEffect(viewModel.state == .speaking ? 1.08 : 1.0)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: viewModel.state == .speaking)

                    CachedImage(url: viewModel.character.avatarURL ?? viewModel.character.photoURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { AppColor.pink }
                    .frame(width: 180, height: 180)
                    .clipShape(Circle())
                }

                Text(viewModel.character.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)

                Text(statusLabel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

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
                    .disabled(typedText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 24)

                HStack(spacing: 40) {
                    Button { viewModel.toggleMute() } label: {
                        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(.white.opacity(0.15), in: Circle())
                    }

                    Button {
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
                }
                .padding(.bottom, 40)
            }

            // TEMP DEBUG overlay — remove once voice call pipeline is verified on device.
            VStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DEBUG")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.yellow)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(viewModel.debugLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Spacer()
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
        typedText = ""
        textFieldFocused = false
        Task { await viewModel.sendTypedText(text) }
    }

    private var elapsedLabel: String {
        let total = Int(viewModel.elapsedSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
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
            case .error: return String(localized: "Call failed")
            }
        }
    }
}

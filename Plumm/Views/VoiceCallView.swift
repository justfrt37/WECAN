//
//  VoiceCallView.swift
//  Tam ekran sesli arama — avatar + durum göstergesi, altyazı yok (bkz. design spec).
//

import SwiftUI

struct VoiceCallView: View {
    @State private var viewModel: CallViewModel
    @Environment(\.dismiss) private var dismiss
    let tokenStore: TokenStore

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

                Spacer()

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 32)
                        .multilineTextAlignment(.center)
                }

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
        }
        .onAppear {
            viewModel.tokenStore = tokenStore
            Task { await viewModel.startCall() }
        }
        .onChange(of: viewModel.state) { _, newState in
            if case .ended = newState {
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    dismiss()
                }
            }
        }
        .onDisappear {
            Task { await viewModel.endCall() }
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
            case .error: return String(localized: "Call failed")
            }
        }
    }
}

//
//  AnalyticsService.swift
//  Plumm
//

import AmplitudeUnified

/// Owns the app-wide Amplitude instance so the SDK is initialized exactly once.
final class AnalyticsService {
    static let shared = AnalyticsService()

    private let amplitude: Amplitude

    private init() {
        let analyticsConfig = AnalyticsConfig(
            autocapture: [.sessions, .appLifecycles, .screenViews]
        )
        let sessionReplayConfig = SessionReplayPlugin.Config(sampleRate: 1.0)

        amplitude = Amplitude(
            apiKey: Config.amplitudeAPIKey,
            analyticsConfig: analyticsConfig,
            sessionReplayConfig: sessionReplayConfig
        )
    }

    func trackSplashScreenViewed() {
        amplitude.track(
            eventType: "Viewed Splash Screen",
            eventProperties: ["prompt_version": "BA400.4"]
        )
        amplitude.flush()
    }
}

//
//  CallService.swift
//  Real-time voice call Edge Functions ile konuşur (voice-call-start/checkpoint/end).
//  Per-turn LLM/TTS is no longer client-driven — voice-call-start now returns
//  everything needed (system prompt, voice, ElevenLabs conversation token) to
//  open an ElevenLabs Agents session directly (bkz. CallViewModel).
//

import Foundation

enum CallServiceError: Error {
    case decoding
    case badStatus(Int, String)
    case insufficientTokens
}

struct CallService {
    private func request(url: URL, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CallServiceError.decoding }
        return (data, http)
    }

    struct StartResult {
        let callSessionId: String
        let conversationToken: String
        let systemPrompt: String
        let voiceId: String
        let stability: Double
    }

    func start(characterId: String, conversationId: String?, reviewMode: Bool) async throws -> StartResult {
        var body: [String: Any] = ["characterId": characterId, "reviewMode": reviewMode]
        if let conversationId { body["conversationId"] = conversationId }
        let (data, http) = try await request(url: Config.voiceCallStartFunctionURL, body: body)
        if http.statusCode == 402 { throw CallServiceError.insufficientTokens }
        guard http.statusCode == 200 else {
            throw CallServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable {
            let callSessionId: String
            let conversationToken: String
            let systemPrompt: String
            let voiceId: String
            let stability: Double
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw CallServiceError.decoding }
        return StartResult(
            callSessionId: decoded.callSessionId,
            conversationToken: decoded.conversationToken,
            systemPrompt: decoded.systemPrompt,
            voiceId: decoded.voiceId,
            stability: decoded.stability
        )
    }

    func checkpoint(callSessionId: String, elapsedSeconds: Double) async throws -> Bool {
        let body: [String: Any] = ["callSessionId": callSessionId, "elapsedSeconds": elapsedSeconds]
        let (data, http) = try await request(url: Config.voiceCallCheckpointFunctionURL, body: body)
        guard http.statusCode == 200 else {
            throw CallServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable { let ok: Bool }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw CallServiceError.decoding }
        return decoded.ok
    }

    @discardableResult
    func end(callSessionId: String, actualElapsedSeconds: Double) async throws -> (tokensCharged: Int, newBalance: Int) {
        let body: [String: Any] = ["callSessionId": callSessionId, "actualElapsedSeconds": actualElapsedSeconds]
        let (data, http) = try await request(url: Config.voiceCallEndFunctionURL, body: body)
        guard http.statusCode == 200 else {
            throw CallServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Response: Decodable { let tokensCharged: Int; let newBalance: Int }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw CallServiceError.decoding }
        return (decoded.tokensCharged, decoded.newBalance)
    }
}

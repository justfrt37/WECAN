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
    /// Sunucu 403: sesli arama Pro+ / Pro Max hakkı, bu abonelikte yok
    /// (bkz. _shared/entitlements.ts).
    case notEntitled
}

struct CallService {
    private func request(url: URL, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var req = SupabaseRequest.post(url: url, bearer: SupabaseRequest.sessionBearer, timeout: 30)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw CallServiceError.decoding }
        return (data, http)
    }

    /// Üç uç da aynı sırayı izliyordu: 200 değilse `badStatus`, decode olmazsa
    /// `decoding`. (Yalnızca `start` bundan ÖNCE 402/403'ü ayrıca ele alır.)
    private func decode<T: Decodable>(_ type: T.Type, from data: Data, http: HTTPURLResponse) throws -> T {
        guard http.statusCode == 200 else {
            throw CallServiceError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw CallServiceError.decoding }
        return decoded
    }

    /// Sunucu cevabıyla alan-alan aynı olduğu için doğrudan decode edilir —
    /// eskiden birebir aynı alanlara sahip ayrı bir `Response` tipine decode
    /// edilip elle kopyalanıyordu.
    struct StartResult: Decodable {
        let callSessionId: String
        let conversationToken: String
        let systemPrompt: String
        let voiceId: String
        let stability: Double
        let speed: Double
        let firstMessage: String
    }

    func start(characterId: String, conversationId: String?, reviewMode: Bool, language: String) async throws -> StartResult {
        var body: [String: Any] = ["characterId": characterId, "reviewMode": reviewMode, "language": language]
        if let conversationId { body["conversationId"] = conversationId }
        let (data, http) = try await request(url: Config.voiceCallStartFunctionURL, body: body)
        if http.statusCode == 402 { throw CallServiceError.insufficientTokens }
        if http.statusCode == 403 { throw CallServiceError.notEntitled }
        return try decode(StartResult.self, from: data, http: http)
    }

    func checkpoint(callSessionId: String, elapsedSeconds: Double) async throws -> Bool {
        let body: [String: Any] = ["callSessionId": callSessionId, "elapsedSeconds": elapsedSeconds]
        let (data, http) = try await request(url: Config.voiceCallCheckpointFunctionURL, body: body)
        struct Response: Decodable { let ok: Bool }
        return try decode(Response.self, from: data, http: http).ok
    }

    @discardableResult
    func end(callSessionId: String, actualElapsedSeconds: Double) async throws -> (tokensCharged: Int, newBalance: Int) {
        let body: [String: Any] = ["callSessionId": callSessionId, "actualElapsedSeconds": actualElapsedSeconds]
        let (data, http) = try await request(url: Config.voiceCallEndFunctionURL, body: body)
        struct Response: Decodable { let tokensCharged: Int; let newBalance: Int }
        let decoded = try decode(Response.self, from: data, http: http)
        return (decoded.tokensCharged, decoded.newBalance)
    }
}

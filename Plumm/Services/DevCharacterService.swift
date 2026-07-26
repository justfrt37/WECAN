//
//  DevCharacterService.swift
//  TEMPORARY / DEV-ONLY — backs CreateCharacterView's DEV steps. Calls the
//  dev-* Edge Functions (dev-upload-image, dev-list-voices, dev-create-character,
//  dev-update-character), all of which independently re-check the caller's uid against the same
//  two-uid allowlist server-side (bkz. DevAccess) no matter what this client
//  sends. DELETE alongside CreateCharacterView's DEV steps once curated-character
//  creation is retired.
//

import Foundation

struct DevVoice: Decodable, Identifiable, Hashable {
    let voiceId: String
    let name: String
    let previewURL: URL?
    let category: String?

    var id: String { voiceId }

    private enum CodingKeys: String, CodingKey {
        case voiceId = "voice_id"
        case name
        case previewURL = "preview_url"
        case category
    }
}

/// One in-chat photo the dev is working with — either a brand-new local pick
/// (not yet uploaded) or an already-uploaded row being edited/kept as-is
/// (edit mode, prefilled from an existing character's character_photos).
enum DevPhotoSource {
    case new(Data)
    case existing(URL)
}

/// One in-chat photo the dev is uploading: real bytes + the description that
/// drives chat-image's Grok match against future user photo requests.
struct DevChatPhotoDraft: Identifiable {
    let id = UUID()
    var source: DevPhotoSource
    var description: String = ""
    var mood: String = ""
}

/// One gallery/profile photo the dev is working with (same new-vs-existing
/// split as DevChatPhotoDraft, without the description/mood fields).
struct DevGalleryPhotoDraft: Identifiable {
    let id = UUID()
    var source: DevPhotoSource
}

/// `characters.builder_selections` jsonb, decoded for edit-mode prefill.
/// Mirrors dev-create-character/create-character's write shape exactly.
struct DevBuilderSelections: Decodable {
    let category: String?
    let personalityRole: String?
    let profession: String?
    let vibe: String?
    let ageRange: String?
    let hairstyle: String?
    let hairColor: String?
    let eyeShape: String?
    let eyeColor: String?
    let noseShape: String?
    let skinTone: String?
    let bodyType: String?

    private enum CodingKeys: String, CodingKey {
        case category
        case personalityRole = "personality_role"
        case profession, vibe
        case ageRange = "age_range"
        case hairstyle
        case hairColor = "hair_color"
        case eyeShape = "eye_shape"
        case eyeColor = "eye_color"
        case noseShape = "nose_shape"
        case skinTone = "skin_tone"
        case bodyType = "body_type"
    }
}

/// Full `characters` row for edit-mode prefill — separate from the app's
/// slim `Character` model because that one doesn't decode `builder_selections`
/// (only its nested `vibe`), and the DEV edit form needs every appearance field.
struct DevCharacterFull: Decodable, Identifiable {
    let id: UUID
    let name: String
    let tagline: String?
    let category: String?
    let profession: String?
    let photoURL: URL?
    let galleryURLs: [URL]
    let interests: [String]
    let exHistory: String?
    let voiceId: String?
    let builderSelections: DevBuilderSelections?

    private enum CodingKeys: String, CodingKey {
        case id, name, tagline, category, profession
        case photoURL = "photo_url"
        case galleryURLs = "gallery_urls"
        case interests
        case exHistory = "ex_history"
        case voiceId = "voice_id"
        case builderSelections = "builder_selections"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        tagline = try? c.decodeIfPresent(String.self, forKey: .tagline)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        profession = try? c.decodeIfPresent(String.self, forKey: .profession)
        photoURL = try? c.decodeIfPresent(URL.self, forKey: .photoURL)
        galleryURLs = (try? c.decode([URL].self, forKey: .galleryURLs)) ?? []
        interests = (try? c.decode([String].self, forKey: .interests)) ?? []
        exHistory = try? c.decodeIfPresent(String.self, forKey: .exHistory)
        voiceId = try? c.decodeIfPresent(String.self, forKey: .voiceId)
        builderSelections = try? c.decodeIfPresent(DevBuilderSelections.self, forKey: .builderSelections)
    }
}

/// One `character_photos` row, for edit-mode prefill of the in-chat photo pool.
struct DevExistingChatPhoto: Decodable, Identifiable {
    let id: UUID
    let url: URL
    let description: String?
    let mood: String?
}

enum DevCharacterServiceError: Error {
    case notAuthorized
    case badResponse
    case server(String)
}

enum DevCharacterService {
    private static func authorizedRequest(_ url: URL) -> URLRequest? {
        guard let accessToken = UserDefaultsManager.shared.accessToken else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        return req
    }

    /// Plain GET against PostgREST — `characters`/`character_photos` are both
    /// public-read (RLS `using (true)`), so no privileged edge function is
    /// needed just to READ them for the edit-mode picker/prefill.
    private static func restGET<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "\(Config.supabaseURL)/rest/v1/\(path)") else { throw DevCharacterServiceError.badResponse }
        var req = URLRequest(url: url)
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        let bearer = UserDefaultsManager.shared.accessToken ?? Config.supabaseAnonKey
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DevCharacterServiceError.badResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// All existing public characters, for the "edit existing character"
    /// picker — same data as CharacterService().fetchAll() but ordered by
    /// name for a browsable list.
    static func fetchAllPublicCharacters() async throws -> [DevCharacterFull] {
        try await restGET("characters?select=*&order=name.asc")
    }

    static func fetchCharacterPhotos(_ characterId: UUID) async throws -> [DevExistingChatPhoto] {
        try await restGET("character_photos?character_id=eq.\(characterId.uuidString)&select=id,url,description,mood&order=sort.asc")
    }

    /// Uploads ONE image (already-compressed PNG data) and returns its public
    /// Storage URL. Called once per photo — see dev-upload-image's note on
    /// why (keeps each request small instead of batching everything).
    static func uploadImage(_ data: Data, kind: String) async throws -> URL {
        guard var req = authorizedRequest(Config.devUploadImageFunctionURL) else { throw DevCharacterServiceError.notAuthorized }
        let body: [String: Any] = ["imageBase64": data.base64EncodedString(), "kind": kind]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DevCharacterServiceError.badResponse }
        struct Resp: Decodable { let url: String? ; let error: String? }
        let decoded = try? JSONDecoder().decode(Resp.self, from: data)
        guard http.statusCode == 200, let urlString = decoded?.url, let url = URL(string: urlString) else {
            throw DevCharacterServiceError.server(decoded?.error ?? "upload_failed")
        }
        return url
    }

    static func listVoices() async throws -> [DevVoice] {
        guard var req = authorizedRequest(Config.devListVoicesFunctionURL) else { throw DevCharacterServiceError.notAuthorized }
        req.httpBody = try JSONSerialization.data(withJSONObject: [String: Any]())

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DevCharacterServiceError.badResponse }
        struct Resp: Decodable { let voices: [DevVoice]?; let error: String? }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        guard http.statusCode == 200, let voices = decoded.voices else {
            throw DevCharacterServiceError.server(decoded.error ?? "list_voices_failed")
        }
        return voices
    }

    /// Shared shape for both create and update — dev-update-character just
    /// requires `bio` non-empty (it never auto-generates, unlike create).
    struct CharacterPayload {
        var name: String
        var category: String
        var profession: String
        var vibe: String
        var personalityRole: String
        var ageRange: String
        var ethnicity: String
        var hairstyle: String
        var hairColor: String
        var eyeShape: String
        var eyeColor: String
        var noseShape: String
        var skinTone: String
        var bodyType: String
        var interests: [String]
        var exHistory: String?
        var bio: String?
        var profileURL: URL
        var galleryURLs: [URL]
        var chatPhotos: [(url: URL, description: String, mood: String?)]
        var voiceId: String?
    }

    private static func wireBody(_ p: CharacterPayload) -> [String: Any] {
        var body: [String: Any] = [
            "name": p.name,
            "category": p.category,
            "profession": p.profession,
            "vibe": p.vibe,
            "personality_role": p.personalityRole,
            "age_range": p.ageRange,
            "ethnicity": p.ethnicity,
            "hairstyle": p.hairstyle,
            "hair_color": p.hairColor,
            "eye_shape": p.eyeShape,
            "eye_color": p.eyeColor,
            "nose_shape": p.noseShape,
            "skin_tone": p.skinTone,
            "body_type": p.bodyType,
            "interests": p.interests,
            "profileUrl": p.profileURL.absoluteString,
            "galleryUrls": p.galleryURLs.map(\.absoluteString),
            "chatPhotos": p.chatPhotos.map { photo -> [String: Any] in
                var row: [String: Any] = ["url": photo.url.absoluteString, "description": photo.description]
                if let mood = photo.mood, !mood.isEmpty { row["mood"] = mood }
                return row
            },
        ]
        if let exHistory = p.exHistory, !exHistory.isEmpty { body["ex_history"] = exHistory }
        if let bio = p.bio, !bio.isEmpty { body["bio"] = bio }
        if let voiceId = p.voiceId, !voiceId.isEmpty { body["voiceId"] = voiceId }
        return body
    }

    @discardableResult
    static func createCurated(_ p: CharacterPayload) async throws -> Character {
        guard var req = authorizedRequest(Config.devCreateCharacterFunctionURL) else { throw DevCharacterServiceError.notAuthorized }
        req.httpBody = try JSONSerialization.data(withJSONObject: wireBody(p))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DevCharacterServiceError.badResponse }
        guard http.statusCode == 200 else {
            struct Err: Decodable { let error: String? }
            let err = try? JSONDecoder().decode(Err.self, from: data)
            throw DevCharacterServiceError.server(err?.error ?? "create_failed")
        }
        return try JSONDecoder().decode(Character.self, from: data)
    }

    /// Updates an EXISTING public character in place (name/appearance/photos/
    /// voice all overwritten from the form) — `created_by` stays untouched
    /// server-side (still NULL, still a catalog row).
    @discardableResult
    static func updateCurated(characterId: UUID, _ p: CharacterPayload) async throws -> Character {
        guard var req = authorizedRequest(Config.devUpdateCharacterFunctionURL) else { throw DevCharacterServiceError.notAuthorized }
        var body = wireBody(p)
        body["characterId"] = characterId.uuidString
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DevCharacterServiceError.badResponse }
        guard http.statusCode == 200 else {
            struct Err: Decodable { let error: String? }
            let err = try? JSONDecoder().decode(Err.self, from: data)
            throw DevCharacterServiceError.server(err?.error ?? "update_failed")
        }
        return try JSONDecoder().decode(Character.self, from: data)
    }
}

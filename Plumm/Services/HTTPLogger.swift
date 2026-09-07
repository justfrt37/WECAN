//
//  HTTPLogger.swift
//  Uygulamadan çıkan HTTP isteklerinin tek log noktası: metot, base URL,
//  endpoint, sorgu parametreleri, gövde, cevap kodu, süre ve cevabın kendisi
//  (JSON ise okunaklı/pretty biçimde).
//
//  NEDEN VAR: ağ çağrıları 18 dosyada, 34 ayrı `URLSession.shared.data(...)`
//  çağrısına dağılmış durumdaydı ve hiçbiri ne isteği ne cevabı loglamıyordu.
//  Bir şey ters gittiğinde elde kalan tek şey servisin kendi `errorMessage`i
//  oluyordu — hangi endpoint'e ne gönderildiği, sunucunun ne döndüğü
//  görünmüyordu (bkz. "2 dk bekledim timeout geldi, hiçbir bilgi yok" vakası:
//  fonksiyon HTTP cevabı hiç döndürmemişti ama istemci tarafında bunu
//  gösteren tek satır yoktu).
//
//  NASIL KULLANILIR: çağrı yerleri `URLSession.shared.data(for:)` yerine
//  `URLSession.shared.logged(for:)` çağırır — dönüş tipi birebir aynı
//  `(Data, URLResponse)`, yani başka hiçbir şey değişmez.
//
//  Loglar `print` DEĞİL, `Logger` üzerinden gider (PurchaseService.diag ve
//  CallViewModel.diag ile aynı desen): print yalnızca Xcode'a bağlıyken
//  görünür, Logger TestFlight/Release'te de Console.app'ten okunur —
//  alt sistem `com.firat.Plumm`, kategori `http`.
//
//  GİZLİLİK: gövdeler YALNIZCA DEBUG derlemelerinde loglanır. Release'te
//  metot/endpoint/durum kodu/süre/boyut kalır, kullanıcı mesajı ya da sunucu
//  cevabının içeriği cihaz loglarına yazılmaz. `Authorization` ve `apikey`
//  başlıkları hiçbir derlemede açık yazılmaz.
//

import Foundation
import OSLog

enum HTTPLogger {
    private static let log = Logger(subsystem: "com.firat.Plumm", category: "http")

    /// İstek/cevap satırlarını eşleştiren sayaç. İstekler eşzamanlı gittiği
    /// için cevaplar sırasız düşer; `#12` gibi bir kimlik olmadan hangi cevabın
    /// hangi isteğe ait olduğu okunamaz.
    private static let counterLock = NSLock()
    private static var counter = 0
    private static func nextID() -> Int {
        counterLock.lock(); defer { counterLock.unlock() }
        counter += 1
        return counter
    }

    /// Gövde logunun üst sınırı. Base64 blob'lar ayrıca eleniyor (bkz.
    /// `elideBlobs`) ama bu, beklenmedik büyük cevaplara karşı sert tavan.
    private static let maxBodyChars = 4000
    /// Bir JSON string'i bundan uzunsa içeriği loglanmaz, yerine boyutu yazılır.
    /// Fotoğraf (base64 JPEG) ve ses gönderimlerinde gövde megabaytlara
    /// çıkıyor; onları olduğu gibi basmak logu kullanılamaz hale getiriyordu.
    private static let maxStringChars = 256

    // MARK: - Genel giriş noktası

    static func begin(_ request: URLRequest) -> Token {
        let id = nextID()
        let method = request.httpMethod ?? "GET"
        let url = request.url
        let base = url.map { "\($0.scheme ?? "")://\($0.host ?? "")" } ?? "?"
        let path = url?.path ?? "?"
        let query = url?.query

        var lines = ["→ #\(id) \(method) \(path)", "     base:   \(base)"]
        if let query, !query.isEmpty {
            lines.append("     query:  \(prettyQuery(query))")
        }
        lines.append("     auth:   \(authSummary(request))")
        #if DEBUG
        if let body = request.httpBody, !body.isEmpty {
            lines.append("     body:   \(pretty(body, contentType: request.value(forHTTPHeaderField: "Content-Type")))")
        }
        #else
        if let body = request.httpBody, !body.isEmpty {
            lines.append("     body:   \(byteCount(body.count))")
        }
        #endif
        log.debug("\(lines.joined(separator: "\n"), privacy: .public)")
        return Token(id: id, method: method, path: path, startedAt: Date())
    }

    static func end(_ token: Token, data: Data, response: URLResponse) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")
        var lines = ["← #\(token.id) \(status) \(statusEmoji(status)) \(token.method) \(token.path)  \(token.elapsedMs)ms  \(byteCount(data.count))"]
        #if DEBUG
        if !data.isEmpty {
            lines.append(pretty(data, contentType: contentType, indent: "     "))
        }
        #endif
        // Hata kodları Release'te de görünür olsun: bir 4xx/5xx'in gövdesi
        // teşhisin tamamı oluyor (ör. {"error":"insufficient_tokens"}) ve
        // içinde kullanıcı içeriği bulunmuyor.
        #if !DEBUG
        if status >= 400, !data.isEmpty {
            lines.append(pretty(data, contentType: contentType, indent: "     ", limit: 600))
        }
        #endif
        let text = lines.joined(separator: "\n")
        if status >= 400 {
            log.error("\(text, privacy: .public)")
        } else {
            log.debug("\(text, privacy: .public)")
        }
    }

    static func fail(_ token: Token, error: Error) {
        // Cevap HİÇ gelmediyse (timeout, bağlantı kopması, sunucunun cevap
        // döndürmeden ölmesi) tek iz burası olur.
        let ns = error as NSError
        log.error("""
            ✖ #\(token.id, privacy: .public) \(token.method, privacy: .public) \(token.path, privacy: .public)  \
            \(token.elapsedMs, privacy: .public)ms  CEVAP YOK — \(ns.domain, privacy: .public) \
            \(ns.code, privacy: .public): \(error.localizedDescription, privacy: .public)
            """)
    }

    struct Token {
        let id: Int
        let method: String
        let path: String
        let startedAt: Date
        var elapsedMs: Int { Int(Date().timeIntervalSince(startedAt) * 1000) }
    }

    // MARK: - Biçimlendirme

    /// Başlıkların DEĞERİ asla loglanmaz; yalnızca hangi kimlikle gidildiği
    /// (kullanıcı jetonu mu anon key mi) ve son 4 karakter yazılır — iki farklı
    /// oturumu ayırt etmeye yeter, jetonu kullanılabilir kılmaya yetmez.
    private static func authSummary(_ request: URLRequest) -> String {
        guard let header = request.value(forHTTPHeaderField: "Authorization"),
              header.hasPrefix("Bearer ") else { return "yok" }
        let token = String(header.dropFirst(7))
        let kind = token.hasPrefix("eyJ") ? "kullanıcı JWT" : "anon/publishable"
        return "\(kind) …\(String(token.suffix(4)))"
    }

    private static func prettyQuery(_ query: String) -> String {
        query.split(separator: "&").map(String.init).joined(separator: "\n             ")
    }

    private static func byteCount(_ count: Int) -> String {
        count < 1024 ? "\(count) B"
            : count < 1024 * 1024 ? String(format: "%.1f KB", Double(count) / 1024)
            : String(format: "%.1f MB", Double(count) / (1024 * 1024))
    }

    private static func statusEmoji(_ status: Int) -> String {
        switch status {
        case 200..<300: return "✓"
        case 300..<400: return "↪"
        case 400..<500: return "⚠"
        default: return "✖"
        }
    }

    /// JSON'u okunaklı bas; JSON değilse (görsel/ses/HTML) içeriği basmadan
    /// tipini ve boyutunu yaz.
    private static func pretty(
        _ data: Data,
        contentType: String?,
        indent: String = "",
        limit: Int? = nil
    ) -> String {
        let type = (contentType ?? "").lowercased()
        if !type.isEmpty, !type.contains("json"), !type.contains("text") {
            return "\(indent)<\(type.split(separator: ";").first.map(String.init) ?? type) \(byteCount(data.count))>"
        }
        let cap = limit ?? maxBodyChars
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            // JSON değil ama metin olabilir (ör. PostgREST hata metni).
            let text = String(data: data, encoding: .utf8) ?? "<\(byteCount(data.count)) ikili veri>"
            return indent + truncate(text, to: cap).replacingOccurrences(of: "\n", with: "\n" + indent)
        }
        let elided = elideBlobs(object)
        guard let out = try? JSONSerialization.data(
            withJSONObject: elided,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: out, encoding: .utf8) else {
            return "\(indent)<JSON basılamadı, \(byteCount(data.count))>"
        }
        return indent + truncate(text, to: cap).replacingOccurrences(of: "\n", with: "\n" + indent)
    }

    /// Değeri asla loglanmaması gereken alanlar. Uzunluk elemesine GÜVENİLMEZ:
    /// `refresh_token` 12 karakter ve o eşiğin altında kalıyor, ama ele geçen
    /// bir refresh token oturumu süresiz devralmaya yeter (canlı doğrulandı:
    /// /auth/v1/token cevabında düz metin olarak loglanıyordu).
    ///
    /// Eşleşme TAM ad üzerinden, alt çizgi/büyük-küçük harf yok sayılarak —
    /// "içinde token geçen her alan" demek `tokenBalance`, `tokenPacks`,
    /// `token_100` gibi loglanması GEREKEN alanları da götürüyordu.
    private static let redactedKeys: Set<String> = [
        "accesstoken", "refreshtoken", "idtoken", "providertoken", "providerrefreshtoken",
        "conversationtoken", "authorization", "apikey", "password", "secret", "jwt",
    ]

    private static func isRedacted(_ key: String) -> Bool {
        redactedKeys.contains(key.replacingOccurrences(of: "_", with: "").lowercased())
    }

    /// JSON içindeki devasa string'leri (base64 fotoğraf/ses, uzun prompt)
    /// yerlerine boyut etiketi koyarak eler, kimlik bilgisi alanlarını ise
    /// komple gizler. Gövdenin ŞEKLİ korunur — hangi alanın gittiği görünür,
    /// içeriği logu boğmaz.
    private static func elideBlobs(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { out, pair in
                out[pair.key] = isRedacted(pair.key) ? "<gizlendi>" : elideBlobs(pair.value)
            }
        case let array as [Any]:
            return array.map { elideBlobs($0) }
        case let string as String where string.count > maxStringChars:
            return "<\(byteCount(string.utf8.count)) metin, ilk 40: \(String(string.prefix(40)))…>"
        default:
            return value
        }
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n… (\(text.count - limit) karakter daha kesildi)"
    }
}

// MARK: - URLSession sarmalayıcıları

extension URLSession {
    /// `data(for:)`nin loglayan hali. Dönüş tipi birebir aynı, çağrı yerlerinde
    /// başka bir değişiklik gerekmez.
    func logged(for request: URLRequest) async throws -> (Data, URLResponse) {
        let token = HTTPLogger.begin(request)
        do {
            let (data, response) = try await data(for: request)
            HTTPLogger.end(token, data: data, response: response)
            return (data, response)
        } catch {
            HTTPLogger.fail(token, error: error)
            throw error
        }
    }

    /// `data(from:)`nin loglayan hali (başlıksız düz GET — CDN görsel/ses
    /// indirmeleri bunu kullanıyor).
    func logged(from url: URL) async throws -> (Data, URLResponse) {
        try await logged(for: URLRequest(url: url))
    }
}

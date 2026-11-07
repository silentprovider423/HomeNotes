import Foundation

/// Eine Notiz aus Nextcloud Notes (API v1). Inhalt ist Markdown; die Kategorie ist der Ordnerpfad („Privat/Rezepte“).
struct Note: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var etag: String?
    var title: String
    var content: String?
    var category: String
    var favorite: Bool
    var modified: Int
    var readonly: Bool?
    var internalPath: String?

    var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }
}

enum NotesError: LocalizedError {
    case notSignedIn, http(Int, String), conflict
    var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "Nicht angemeldet")
        case .http(let c, let m): String(localized: "Server-Fehler \(c): \(m)")
        case .conflict: String(localized: "Die Notiz wurde inzwischen woanders geändert.")
        }
    }
}

/// Spricht mit der Nextcloud-App „Notes“ (https://github.com/nextcloud/notes, API v1.3+).
/// Anmeldung über ein App-Passwort aus dem Nextcloud-Login (Login Flow v2) – das echte Passwort kennt die App nie.
final class NotesClient: @unchecked Sendable {
    static let shared = NotesClient()

    private(set) var server: URL?
    private(set) var user: String?
    private var password: String?
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
    private let decoder = JSONDecoder()

    init() {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "server") { server = URL(string: s) }
        user = d.string(forKey: "user")
        password = Keychain.get("appPassword")
        #if DEBUG
        // Simulator-Tests: Zugang per Startumgebung (SIMCTL_CHILD_NOTES_*), nichts gespeichert
        let env = ProcessInfo.processInfo.environment
        if let s = env["NOTES_SERVER"], let u = env["NOTES_USER"], let p = env["NOTES_PASSWORD"] {
            server = URL(string: s); user = u; password = p
        }
        #endif
    }

    var isSignedIn: Bool { server != nil && user != nil && password != nil }

    func signIn(server: URL, user: String, appPassword: String) {
        self.server = server; self.user = user; password = appPassword
        UserDefaults.standard.set(server.absoluteString, forKey: "server")
        UserDefaults.standard.set(user, forKey: "user")
        Keychain.set(appPassword, for: "appPassword")
    }

    func signOut() {
        password = nil; user = nil
        UserDefaults.standard.removeObject(forKey: "user")
        Keychain.set(nil, for: "appPassword")
    }

    // MARK: Notizen

    /// Alle Notizen ohne Inhalt (schnell, für die Listen); `pruneBefore` lässt unveränderte weg.
    func list(withContent: Bool = false, pruneBefore: Int? = nil) async throws -> [Note] {
        var q: [String: String] = [:]
        if !withContent { q["exclude"] = "content" }
        if let pruneBefore { q["pruneBefore"] = String(pruneBefore) }
        return try await request("notes", query: q)
    }

    func note(_ id: Int) async throws -> Note { try await request("notes/\(id)") }

    func create(title: String, content: String, category: String, favorite: Bool = false) async throws -> Note {
        try await request("notes", method: "POST",
                          body: ["title": title, "content": content, "category": category, "favorite": favorite])
    }

    /// Speichern mit ETag: Hat jemand anderes die Notiz inzwischen geändert, kommt `.conflict` statt Überschreiben.
    func update(_ n: Note, content: String? = nil, title: String? = nil, category: String? = nil, favorite: Bool? = nil) async throws -> Note {
        var body: [String: Any] = [:]
        if let content { body["content"] = content }
        if let title { body["title"] = title }
        if let category { body["category"] = category }
        if let favorite { body["favorite"] = favorite }
        return try await request("notes/\(n.id)", method: "PUT", body: body, ifMatch: n.etag)
    }

    func delete(_ id: Int) async throws {
        let _: EmptyReply = try await request("notes/\(id)", method: "DELETE")
    }

    // MARK: Basis

    private struct EmptyReply: Decodable {}

    private func request<T: Decodable>(_ path: String, query: [String: String] = [:], method: String = "GET",
                                       body: [String: Any]? = nil, ifMatch: String? = nil) async throws -> T {
        guard let server, let user, let password else { throw NotesError.notSignedIn }
        var c = URLComponents(url: server.appendingPathComponent("index.php/apps/notes/api/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!)
        req.httpMethod = method
        req.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let ifMatch { req.setValue("\"\(ifMatch)\"", forHTTPHeaderField: "If-Match") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 412 { throw NotesError.conflict }
        guard (200..<300).contains(code) else {
            throw NotesError.http(code, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        if T.self == EmptyReply.self { return EmptyReply() as! T }
        return try decoder.decode(T.self, from: data)
    }
}

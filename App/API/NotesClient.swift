import Foundation

/// Eine Notiz, wie sie die Nextcloud-App „Notes“ (API v1) liefert. Bei `pruneBefore` kommen unveränderte Notizen
/// nur mit `id` zurück – deshalb sind alle anderen Felder optional.
nonisolated struct RemoteNote: Codable, Identifiable, Hashable, Sendable {
    var id: Int
    var etag: String?
    var title: String?
    var content: String?
    var category: String?
    var favorite: Bool?
    var modified: Int?
    var readonly: Bool?
    var error: Bool?

    /// Nur die ID geliefert (unverändert seit `pruneBefore`).
    var isPruned: Bool { title == nil && modified == nil }
}

/// Server-Fähigkeiten aus `/ocs/v2.php/cloud/capabilities` (Abschnitt `notes`).
nonisolated struct NotesCapabilities: Codable, Hashable, Sendable {
    var apiVersions: [String]
    var version: String
    var notesPath: String?

    /// Anhänge gibt es ab API 1.4 (Notes 4.12.3).
    var supportsAttachments: Bool { apiVersions.contains { Self.compare($0, "1.4") >= 0 && $0.hasPrefix("1.") } }
    /// Anhänge löschen ab Notes 6.1.
    var supportsAttachmentDelete: Bool { Self.compare(version, "6.1") >= 0 }
    /// Mindestens API 1.2 (ETag, If-Match, Einstellungen) brauchen wir.
    var isUsable: Bool { apiVersions.contains { $0.hasPrefix("1.") && Self.compare($0, "1.2") >= 0 } }

    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

nonisolated struct NotesSettings: Codable, Hashable, Sendable {
    var notesPath: String
    var fileSuffix: String?
}

/// Ein Eintrag aus dem WebDAV-Ordner der Notizen (für Ordner, die noch keine Notiz enthalten, und Erstellungsdaten).
nonisolated struct DAVItem: Hashable, Sendable {
    var path: String          // relativ zum Notizordner, ohne führenden/abschließenden Schrägstrich
    var isFolder: Bool
    var fileId: Int?
    var created: Int?
}

nonisolated enum NotesError: LocalizedError, Equatable {
    case notSignedIn, http(Int, String), conflict(RemoteNote?), offline, notNotesServer

    var errorDescription: String? {
        switch self {
        case .notSignedIn: String(localized: "Nicht angemeldet")
        case .http(let c, let m): String(localized: "Server-Fehler \(c): \(m)")
        case .conflict: String(localized: "Die Notiz wurde inzwischen woanders geändert.")
        case .offline: String(localized: "Keine Verbindung zum Server")
        case .notNotesServer: String(localized: "Auf diesem Server ist die App „Notes“ nicht installiert.")
        }
    }

    var isOffline: Bool { self == .offline }
}

/// Spricht mit der Nextcloud-App „Notes“ (https://github.com/nextcloud/notes, API v1.2+), dazu WebDAV und OCS
/// desselben Servers. Anmeldung mit einem App-Passwort aus dem Nextcloud-Login (Login Flow v2).
final class NotesClient: @unchecked Sendable {
    static let shared = NotesClient()

    private(set) var server: URL?
    private(set) var user: String?          // Anmeldename (für Basic-Auth)
    private(set) var userId: String?        // Nextcloud-Benutzer-ID (für WebDAV-Pfade)
    private var password: String?
    /// Zugang kommt aus der Startumgebung (Debug) – dann beim Abmelden kein App-Passwort am Server löschen.
    private(set) var fromEnvironment = false

    let session: URLSession
    private let decoder = JSONDecoder()

    init(server: URL? = nil, user: String? = nil, password: String? = nil, persistent: Bool = true) {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil           // Nextcloud-Sitzungscookies würden sonst Basic-Auth überlagern
        c.httpShouldSetCookies = false
        session = URLSession(configuration: c)
        if let server, let user, let password {
            self.server = server; self.user = user; self.password = password; fromEnvironment = true
            return
        }
        guard persistent else { return }
        let d = UserDefaults.standard
        if let s = d.string(forKey: "server") { self.server = URL(string: s) }
        self.user = d.string(forKey: "user")
        self.userId = d.string(forKey: "userId")
        self.password = Keychain.get("appPassword")
        #if DEBUG
        // Simulator-Tests: Zugang per Startumgebung (SIMCTL_CHILD_NOTES_*), nichts wird gespeichert
        let env = ProcessInfo.processInfo.environment
        if let s = env["NOTES_SERVER"], let u = env["NOTES_USER"], let p = env["NOTES_PASSWORD"], !s.isEmpty {
            self.server = URL(string: s); self.user = u; self.password = p; self.userId = nil; fromEnvironment = true
        }
        #endif
    }

    var isSignedIn: Bool { server != nil && user != nil && password != nil }

    /// Schlüssel für den lokalen Zwischenspeicher je Konto.
    var accountKey: String {
        let raw = (server?.absoluteString ?? "") + "|" + (user ?? "")
        var h: UInt64 = 1469598103934665603
        for b in raw.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }

    func signIn(server: URL, user: String, appPassword: String) {
        self.server = server; self.user = user; password = appPassword; userId = nil; fromEnvironment = false
        UserDefaults.standard.set(server.absoluteString, forKey: "server")
        UserDefaults.standard.set(user, forKey: "user")
        UserDefaults.standard.removeObject(forKey: "userId")
        Keychain.set(appPassword, for: "appPassword")
    }

    /// Abmelden: App-Passwort am Server widerrufen (nur wenn es aus dem Login-Flow stammt), lokal vergessen.
    func signOut() async {
        if !fromEnvironment, isSignedIn {
            _ = try? await raw(ocs("core/apppassword"), method: "DELETE")
        }
        password = nil; user = nil; userId = nil
        UserDefaults.standard.removeObject(forKey: "user")
        UserDefaults.standard.removeObject(forKey: "userId")
        Keychain.set(nil, for: "appPassword")
    }

    // MARK: Konto & Fähigkeiten

    func capabilities() async throws -> NotesCapabilities {
        let (data, _) = try await raw(ocs("cloud/capabilities"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let caps = ((root["ocs"] as? [String: Any])?["data"] as? [String: Any])?["capabilities"] as? [String: Any],
              let notes = caps["notes"] as? [String: Any] else { throw NotesError.notNotesServer }
        return NotesCapabilities(apiVersions: notes["api_version"] as? [String] ?? [],
                                 version: notes["version"] as? String ?? "0",
                                 notesPath: notes["notes_path"] as? String)
    }

    /// Nextcloud-Benutzer-ID (kann sich vom Anmeldenamen unterscheiden, z. B. bei Anmeldung per E-Mail).
    @discardableResult
    func loadUserId() async throws -> String {
        if let userId { return userId }
        let (data, _) = try await raw(ocs("cloud/user"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = ((root["ocs"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String else {
            throw NotesError.http(0, "user")
        }
        userId = id
        if !fromEnvironment { UserDefaults.standard.set(id, forKey: "userId") }
        return id
    }

    func settings() async throws -> NotesSettings { try await json("settings") }

    // MARK: Notizen

    struct ListResult: Sendable { var notes: [RemoteNote]; var lastModified: Int? }

    /// Alle Notizen. `pruneBefore` lässt unveränderte weg (nur `id`), große Bestände kommen in Stücken.
    func list(pruneBefore: Int? = nil, chunkSize: Int = 200) async throws -> ListResult {
        var all: [RemoteNote] = []
        var cursor: String?
        var lastModified: Int?
        repeat {
            var q: [String: String] = ["chunkSize": String(chunkSize)]
            if let pruneBefore { q["pruneBefore"] = String(pruneBefore) }
            if let cursor { q["chunkCursor"] = cursor }
            let (data, resp) = try await raw(api("notes", query: q))
            let page = try decoder.decode([RemoteNote].self, from: data)
            // Bei Stücken stehen später gelieferte Volltexte vor früheren Kurzfassungen
            for n in page {
                if let i = all.firstIndex(where: { $0.id == n.id }) {
                    if !n.isPruned { all[i] = n }
                } else { all.append(n) }
            }
            cursor = resp.value(forHTTPHeaderField: "X-Notes-Chunk-Cursor")
            if let lm = resp.value(forHTTPHeaderField: "Last-Modified"), let d = Self.httpDate(lm) {
                lastModified = max(lastModified ?? 0, Int(d.timeIntervalSince1970))
            }
        } while cursor != nil
        return ListResult(notes: all, lastModified: lastModified)
    }

    func note(_ id: Int) async throws -> RemoteNote { try await json("notes/\(id)") }

    func create(title: String, content: String, category: String, favorite: Bool = false, modified: Int? = nil) async throws -> RemoteNote {
        var body: [String: Any] = ["title": title, "content": content, "category": category, "favorite": favorite]
        if let modified { body["modified"] = modified }
        return try await json("notes", method: "POST", body: body)
    }

    /// Speichern mit ETag: Hat jemand anderes die Notiz inzwischen geändert, kommt `.conflict(serverStand)`.
    func update(id: Int, etag: String?, content: String? = nil, title: String? = nil, category: String? = nil,
                favorite: Bool? = nil) async throws -> RemoteNote {
        var body: [String: Any] = [:]
        if let content { body["content"] = content }
        if let title { body["title"] = title }
        if let category { body["category"] = category }
        if let favorite { body["favorite"] = favorite }
        return try await json("notes/\(id)", method: "PUT", body: body, ifMatch: etag)
    }

    func delete(_ id: Int) async throws {
        do { _ = try await raw(api("notes/\(id)"), method: "DELETE") }
        catch NotesError.http(404, _) { }      // schon weg – Ziel erreicht
    }

    // MARK: Anhänge (API 1.4, Löschen ab Notes 6.1)

    func attachment(note id: Int, path: String) async throws -> Data {
        let (data, _) = try await raw(api("attachment/\(id)", query: ["path": path]))
        return data
    }

    /// Lädt eine Datei hoch und gibt den Pfad relativ zum Kategorie-Ordner zurück (`.attachments.<id>/name.jpg`).
    func uploadAttachment(note id: Int, data: Data, filename: String, mimeType: String) async throws -> String {
        let boundary = "HomeNotes-\(UUID().uuidString)"
        var body = Data()
        let safeName = filename.replacingOccurrences(of: "\"", with: "")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var req = try authorized(api("attachment/\(id)"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let (out, _) = try await send(req, body: body)
        struct Reply: Decodable { let filename: String }
        return try decoder.decode(Reply.self, from: out).filename
    }

    func deleteAttachment(note id: Int, path: String) async throws {
        do { _ = try await raw(api("attachment/\(id)", query: ["path": path]), method: "DELETE") }
        catch NotesError.http(404, _) { }
    }

    // MARK: WebDAV (Ordner, Erstellungsdaten)

    /// Alle Ordner und Dateien unterhalb des Notizordners (eine Anfrage mit `Depth: infinity`).
    func davList(notesPath: String) async throws -> [DAVItem] {
        let uid = try await loadUserId()
        let base = davBase(uid, notesPath)
        var req = try authorized(base)
        req.httpMethod = "PROPFIND"
        req.setValue("infinity", forHTTPHeaderField: "Depth")
        req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        let xml = """
        <?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">\
        <d:prop><d:resourcetype/><oc:fileid/><nc:creation_time/></d:prop></d:propfind>
        """
        let (data, _) = try await send(req, body: Data(xml.utf8))
        let prefix = base.path.removingPercentEncoding ?? base.path
        return DAVParser.parse(data).compactMap { item in
            guard var p = item.href.removingPercentEncoding else { return nil }
            guard p.hasPrefix(prefix) else { return nil }
            p.removeFirst(prefix.count)
            p = p.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !p.isEmpty else { return nil }
            return DAVItem(path: p, isFolder: item.isCollection, fileId: item.fileId, created: item.created.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    func davMakeFolder(notesPath: String, folder: String) async throws {
        let uid = try await loadUserId()
        // Elternordner zuerst (MKCOL legt keine Zwischenebenen an)
        var acc: [String] = []
        for part in folder.split(separator: "/") {
            acc.append(String(part))
            do { _ = try await raw(davBase(uid, notesPath, acc.joined(separator: "/")), method: "MKCOL") }
            catch NotesError.http(405, _) { }          // existiert schon
        }
    }

    func davMove(notesPath: String, from: String, to: String) async throws {
        let uid = try await loadUserId()
        var req = try authorized(davBase(uid, notesPath, from))
        req.httpMethod = "MOVE"
        req.setValue(davBase(uid, notesPath, to).absoluteString, forHTTPHeaderField: "Destination")
        req.setValue("F", forHTTPHeaderField: "Overwrite")
        _ = try await send(req)
    }

    func davDelete(notesPath: String, path: String) async throws {
        let uid = try await loadUserId()
        do { _ = try await raw(davBase(uid, notesPath, path), method: "DELETE") }
        catch NotesError.http(404, _) { }
    }

    // MARK: Basis

    private func api(_ path: String, query: [String: String] = [:]) throws -> URL {
        guard let server else { throw NotesError.notSignedIn }
        var c = URLComponents(url: server.appendingPathComponent("index.php/apps/notes/api/v1/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            // „+“ würde PHP als Leerzeichen lesen
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return c.url!
    }

    private func ocs(_ path: String) throws -> URL {
        guard let server else { throw NotesError.notSignedIn }
        var c = URLComponents(url: server.appendingPathComponent("ocs/v2.php/" + path), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "format", value: "json")]
        return c.url!
    }

    private func davBase(_ uid: String, _ notesPath: String, _ sub: String = "") -> URL {
        var url = server!.appendingPathComponent("remote.php/dav/files").appendingPathComponent(uid)
        for part in (notesPath + "/" + sub).split(separator: "/") { url.appendPathComponent(String(part)) }
        return url.appendingPathComponent("", isDirectory: true)     // Ordner-URLs mit „/“ am Ende
    }

    private func authorized(_ url: URL) throws -> URLRequest {
        guard let user, let password else { throw NotesError.notSignedIn }
        var req = URLRequest(url: url)
        req.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("true", forHTTPHeaderField: "OCS-APIRequest")
        req.setValue("HomeNotes", forHTTPHeaderField: "User-Agent")
        return req
    }

    @discardableResult
    func raw(_ url: URL, method: String = "GET", body: [String: Any]? = nil, ifMatch: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = try authorized(url)
        req.httpMethod = method
        if let ifMatch { req.setValue("\"\(ifMatch)\"", forHTTPHeaderField: "If-Match") }
        var data: Data?
        if let body {
            data = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await send(req, body: data)
    }

    private func send(_ req: URLRequest, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        let data: Data, resp: URLResponse
        do {
            if let body { (data, resp) = try await session.upload(for: req, from: body) }
            else { (data, resp) = try await session.data(for: req) }
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch is URLError {
            throw NotesError.offline
        }
        guard let http = resp as? HTTPURLResponse else { throw NotesError.offline }
        if http.statusCode == 412 {
            throw NotesError.conflict(try? decoder.decode(RemoteNote.self, from: data))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NotesError.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }
        return (data, http)
    }

    private func json<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, ifMatch: String? = nil) async throws -> T {
        let (data, _) = try await raw(api(path), method: method, body: body, ifMatch: ifMatch)
        return try decoder.decode(T.self, from: data)
    }

    static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }
}

/// Kleiner Leser für WebDAV-Multistatus-Antworten.
final class DAVParser: NSObject, XMLParserDelegate {
    struct Item { var href = ""; var isCollection = false; var fileId: Int?; var created: Int? }
    private var items: [Item] = []
    private var current: Item?
    private var text = ""

    static func parse(_ data: Data) -> [Item] {
        let p = DAVParser()
        let x = XMLParser(data: data)
        x.shouldProcessNamespaces = true
        x.delegate = p
        x.parse()
        return p.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "response" { current = Item() }
        if name == "collection" { current?.isCollection = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "href": current?.href = t
        case "fileid": current?.fileId = Int(t)
        case "creation_time": current?.created = Int(t)
        case "response": if let c = current { items.append(c) }; current = nil
        default: break
        }
        text = ""
    }
}

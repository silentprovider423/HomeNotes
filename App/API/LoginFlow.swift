import Foundation

/// Nextcloud Login Flow v2: Die App öffnet die Anmeldeseite der eigenen Nextcloud im Browser, der Nutzer meldet sich
/// dort an (auch mit Zwei-Faktor), und die App bekommt ein eigenes App-Passwort – das echte Passwort sieht sie nie.
/// https://docs.nextcloud.com/server/latest/developer_manual/client_apis/LoginFlow/index.html#login-flow-v2
enum LoginFlow {
    struct Start: Decodable {
        struct Poll: Decodable { let token: String; let endpoint: URL }
        let poll: Poll
        let login: URL
    }
    struct Result: Decodable { let server: URL; let loginName: String; let appPassword: String }

    /// Schritt 1: Anmeldeseite + Abfrage-Adresse holen. Eingabe ohne http(s):// → https.
    static func start(_ input: String) async throws -> Start {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let base = URL(string: s) else { throw NotesError.http(0, "URL") }
        var req = URLRequest(url: base.appendingPathComponent("index.php/login/v2"))
        req.httpMethod = "POST"
        req.setValue("HomeNotes", forHTTPHeaderField: "User-Agent")   // erscheint so in Nextclouds Geräteliste
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NotesError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(localized: "Keine Nextcloud unter dieser Adresse"))
        }
        return try JSONDecoder().decode(Start.self, from: data)
    }

    /// Schritt 2: alle 2 s nachfragen, bis der Nutzer im Browser fertig ist (max. 20 Minuten, wie Nextcloud).
    static func poll(_ p: Start.Poll) async throws -> Result {
        for _ in 0..<600 {
            try Task.checkCancellation()
            var req = URLRequest(url: p.endpoint)
            req.httpMethod = "POST"
            req.httpBody = "token=\(p.token)".data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let r = try? JSONDecoder().decode(Result.self, from: data) { return r }
            try await Task.sleep(for: .seconds(2))
        }
        throw NotesError.http(0, String(localized: "Anmeldung abgelaufen"))
    }
}

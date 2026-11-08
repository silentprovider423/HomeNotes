import Foundation
import Observation

/// Eine Notiz im lokalen Zwischenspeicher (Serverstand + noch nicht hochgeladene Änderungen).
nonisolated struct LocalNote: Codable, Identifiable, Hashable, Sendable {
    var id: Int                      // Server-ID; negativ = nur lokal, noch nicht angelegt
    var title: String
    var content: String
    var category: String
    var favorite: Bool
    var modified: Int
    var created: Int?
    var etag: String?
    var readonly = false
    var base: String?                // letzter gemeinsamer Inhalt mit dem Server (für Zusammenführen)
    var dirtyContent = false
    var dirtyMeta = false            // Anpinnen / Ordner geändert
    var createAttempted: Bool? = nil // Anlegen wurde schon einmal gesendet (Antwort evtl. verloren)

    var isLocalOnly: Bool { id < 0 }
    var isDirty: Bool { dirtyContent || dirtyMeta || isLocalOnly }
    var modifiedDate: Date { Date(timeIntervalSince1970: TimeInterval(modified)) }
    var createdDate: Date? { created.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    /// Titel für Listen: erste Zeile, sonst Server-Titel.
    var displayTitle: String {
        let t = MarkdownCodec.title(of: content)
        return t.isEmpty ? (content.isEmpty && !title.isEmpty && !isLocalOnly ? title : String(localized: "Neue Notiz")) : t
    }

    /// Zweite Zeile der Liste: erster Text nach dem Titel.
    var preview: String {
        var lines = MarkdownCodec.plainText(content).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !lines.isEmpty { lines.removeFirst() }
        return lines.first ?? ""
    }

    /// Erstes Bild (für die Miniatur in der Liste).
    var firstImagePath: String? {
        guard content.contains("![") else { return nil }
        return MarkdownCodec.attachmentPaths(content).first { AttachmentRef.looksLikeImage($0) }
    }

    init(id: Int, title: String, content: String, category: String, favorite: Bool, modified: Int) {
        self.id = id; self.title = title; self.content = content; self.category = category
        self.favorite = favorite; self.modified = modified
    }

    init(remote r: RemoteNote) {
        self.init(id: r.id, title: r.title ?? "", content: r.content ?? "", category: r.category ?? "",
                  favorite: r.favorite ?? false, modified: r.modified ?? Int(Date().timeIntervalSince1970))
        etag = r.etag; readonly = r.readonly ?? false; base = r.content
    }

    mutating func adopt(_ r: RemoteNote) {
        if let t = r.title { title = t }
        if let c = r.content { content = c; base = c }
        if let c = r.category { category = c }
        if let f = r.favorite { favorite = f }
        if let m = r.modified { modified = m }
        if let e = r.etag { etag = e }
        readonly = r.readonly ?? readonly
    }
}

/// Lokal „Zuletzt gelöscht“ – Nextcloud Notes hat keinen Papierkorb in der API, darum hält die App eine Kopie 30 Tage.
nonisolated struct TrashedNote: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var originalId: Int
    var title: String
    var content: String
    var category: String
    var favorite: Bool
    var modified: Int
    var deletedAt = Date()
    var files: [String: String] = [:]     // Anhang-Pfad → Dateiname im lokalen Papierkorb-Ordner

    var daysLeft: Int { max(0, 30 - Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day!) }
    var displayTitle: String { let t = MarkdownCodec.title(of: content); return t.isEmpty ? title : t }
}

nonisolated enum FolderID: Hashable, Codable, Sendable {
    case all, category(String), trash
}

nonisolated enum NoteSort: String, Codable, CaseIterable, Sendable { case modified, created, title }

/// Datenhaltung + Abgleich mit Nextcloud. Alle Änderungen landen sofort lokal (offline nutzbar) und werden im
/// Hintergrund hochgeladen; beim Speichern immer mit If-Match, bei 412 wird zusammengeführt oder eine Kopie angelegt.
@MainActor @Observable
final class NoteStore {
    static let shared = NoteStore(client: .shared)

    private(set) var notes: [LocalNote] = []
    private(set) var trash: [TrashedNote] = []
    private(set) var davFolders: Set<String> = []
    private(set) var isSyncing = false
    private(set) var offline = false
    private(set) var lastError: String?
    private(set) var capabilities: NotesCapabilities?
    private(set) var notesPath = "Notes"
    private(set) var lastSync: Date?
    /// Wird bei jeder Änderung durch den Server erhöht – der offene Editor lädt dann neu.
    private(set) var serverRevision = 0

    let client: NotesClient
    private var lastModifiedHeader: Int?
    private var nextTempId = -1
    private var idMap: [Int: Int] = [:]          // lokale ID → Server-ID nach dem Anlegen
    private var pendingDeletes: Set<Int> = []
    private var lastSent: [Int: String] = [:]      // zuletzt gesendeter Inhalt je Notiz (Antwort kann verloren gehen)
    private var index = SearchIndex()
    private var pushTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var syncAgain = false
    private let root: URL
    /// Ordner dieses Kontos (Zwischenspeicher, wartende Anhänge, Papierkorb).
    var directory: URL { root.appendingPathComponent(client.accountKey, isDirectory: true) }

    init(client: NotesClient, directory: URL? = nil) {
        self.client = client
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeNotes", isDirectory: true)
        load()
    }

    // MARK: Abfragen

    func note(_ id: Int) -> LocalNote? {
        let id = resolve(id)
        return notes.first { $0.id == id }
    }

    /// Nach dem ersten Hochladen bekommt eine neue Notiz ihre Server-ID.
    func resolve(_ id: Int) -> Int { idMap[id] ?? id }

    /// Alle Ordnerpfade (Kategorien), inklusive Elternordner und leerer Ordner vom Server.
    var folders: [String] {
        var set = davFolders
        for n in notes where !n.category.isEmpty {
            var parts: [String] = []
            for p in n.category.split(separator: "/") { parts.append(String(p)); set.insert(parts.joined(separator: "/")) }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func children(of folder: String) -> [String] {
        folders.filter { f in
            folder.isEmpty ? !f.contains("/") : f.hasPrefix(folder + "/") && !f.dropFirst(folder.count + 1).contains("/")
        }
    }

    func notes(in folder: FolderID) -> [LocalNote] {
        switch folder {
        case .all: notes
        case .category(let c): notes.filter { $0.category == c }
        case .trash: []
        }
    }

    func count(_ folder: FolderID) -> Int {
        if case .trash = folder { return trash.count }
        return notes(in: folder).count
    }

    func sorted(_ list: [LocalNote], by sort: NoteSort, ascending: Bool) -> [LocalNote] {
        list.sorted { a, b in
            switch sort {
            case .title:
                let r = a.displayTitle.localizedStandardCompare(b.displayTitle)
                return ascending ? r == .orderedAscending : r == .orderedDescending
            case .created:
                let x = a.created ?? a.modified, y = b.created ?? b.modified
                return ascending ? x < y : x > y
            case .modified:
                return ascending ? a.modified < b.modified : a.modified > b.modified
            }
        }
    }

    /// Volltextsuche im lokalen Index; Treffer im Titel zuerst, dann nach Bearbeitungsdatum.
    func search(_ query: String, in folder: FolderID = .all) -> [LocalNote] {
        let hits = index.search(query)
        return notes(in: folder).filter { hits[$0.id] != nil }.sorted {
            let a = hits[$0.id]!, b = hits[$1.id]!
            return a != b ? a > b : $0.modified > $1.modified
        }
    }

    // MARK: Ändern (lokal zuerst)

    /// Neue, leere Notiz – sie existiert nur lokal, bis etwas darin steht.
    func createNote(category: String, content: String = "") -> Int {
        let id = nextTempId
        nextTempId -= 1
        var n = LocalNote(id: id, title: "", content: content, category: category, favorite: false, modified: now)
        n.created = now
        notes.append(n)
        reindex(n)
        if !content.isEmpty { changed() }
        return id
    }

    func updateContent(_ id: Int, _ markdown: String) {
        guard let i = idx(id), notes[i].content != markdown, !notes[i].readonly else { return }
        notes[i].content = markdown
        notes[i].modified = now
        if !notes[i].isLocalOnly { notes[i].dirtyContent = true }
        reindex(notes[i])
        changed()
    }

    /// Leere neue Notizen beim Verlassen wegwerfen (wie Apple).
    func discardIfEmpty(_ id: Int) {
        guard let i = idx(id) else { return }
        let n = notes[i]
        guard n.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if n.isLocalOnly {
            notes.remove(at: i); index.remove(n.id); scheduleSave()
        } else if n.dirtyContent {
            // ganz geleert → wie Apple löschen, der vorherige Stand bleibt in „Zuletzt gelöscht“
            if let b = n.base, !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                trash.insert(TrashedNote(originalId: n.id, title: n.title, content: b, category: n.category,
                                         favorite: n.favorite, modified: n.modified), at: 0)
            }
            notes.remove(at: i); index.remove(n.id)
            pendingDeletes.insert(n.id)
            changed()
        }
    }

    func setFavorite(_ ids: [Int], _ on: Bool) {
        for id in ids { if let i = idx(id) { notes[i].favorite = on; notes[i].dirtyMeta = true } }
        changed()
    }

    func move(_ ids: [Int], to category: String) {
        for id in ids {
            if let i = idx(id), notes[i].category != category, !notes[i].readonly {
                notes[i].category = category; notes[i].dirtyMeta = true
            }
        }
        changed()
    }

    /// In „Zuletzt gelöscht“ legen und am Server löschen.
    func delete(_ ids: [Int]) {
        for id in ids {
            guard let i = idx(id) else { continue }
            let n = notes[i]
            if !n.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                var t = TrashedNote(originalId: n.id, title: n.title, content: n.content, category: n.category,
                                    favorite: n.favorite, modified: n.modified)
                t.files = keepAttachments(of: n, trashId: t.id)
                trash.insert(t, at: 0)
            }
            notes.remove(at: i)
            index.remove(n.id)
            if !n.isLocalOnly { pendingDeletes.insert(n.id) }
        }
        changed()
    }

    /// Notiz aus „Zuletzt gelöscht“ zurückholen: wird am Server neu angelegt, Anhänge werden neu hochgeladen.
    func restore(_ trashIds: [UUID]) {
        for tid in trashIds {
            guard let k = trash.firstIndex(where: { $0.id == tid }) else { continue }
            let t = trash.remove(at: k)
            var content = t.content
            for (path, file) in t.files {
                let src = trashDir(t.id).appendingPathComponent(file)
                let name = (path.removingPercentEncoding ?? path).split(separator: "/").last.map(String.init) ?? file
                if let ref = try? stagePending(from: src, name: name) { content = content.replacingOccurrences(of: path, with: ref) }
            }
            try? FileManager.default.removeItem(at: trashDir(t.id))
            let id = createNote(category: t.category, content: content)
            if let i = idx(id) { notes[i].favorite = t.favorite; notes[i].modified = t.modified }
        }
        changed()
    }

    func purge(_ trashIds: [UUID]) {
        for tid in trashIds { try? FileManager.default.removeItem(at: trashDir(tid)) }
        trash.removeAll { trashIds.contains($0.id) }
        scheduleSave()
    }

    // MARK: Ordner (WebDAV)

    func createFolder(_ path: String) async throws {
        let clean = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "/")
        guard !clean.isEmpty else { return }
        try await client.davMakeFolder(notesPath: notesPath, folder: clean)
        var parts: [String] = []
        for p in clean.split(separator: "/") { parts.append(String(p)); davFolders.insert(parts.joined(separator: "/")) }
        scheduleSave()
    }

    func renameFolder(_ path: String, to newName: String) async throws {
        let name = newName.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        let target = parent.isEmpty ? name : parent + "/" + name
        guard target != path else { return }
        await push()                                // offene Änderungen vorher hoch
        try await client.davMove(notesPath: notesPath, from: path, to: target)
        func re(_ c: String) -> String { c == path ? target : c.hasPrefix(path + "/") ? target + c.dropFirst(path.count) : c }
        for i in notes.indices { notes[i].category = re(notes[i].category) }
        davFolders = Set(davFolders.map(re))
        scheduleSave()
        await sync()
    }

    /// Ordner löschen: Notizen darin (auch in Unterordnern) wandern nach „Zuletzt gelöscht“.
    func deleteFolder(_ path: String) async throws {
        let ids = notes.filter { $0.category == path || $0.category.hasPrefix(path + "/") }.map(\.id)
        delete(ids)
        await push()
        try await client.davDelete(notesPath: notesPath, path: path)
        davFolders = davFolders.filter { $0 != path && !$0.hasPrefix(path + "/") }
        scheduleSave()
    }

    // MARK: Anhänge

    /// Neuen Anhang vormerken: Datei lokal ablegen, Markdown-Verweis zurückgeben. Hochgeladen wird beim Abgleich.
    func addAttachment(data: Data, filename: String) throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try stagePending(from: tmp, name: filename)
    }

    private func stagePending(from src: URL, name: String) throws -> String {
        let uuid = UUID().uuidString
        let safe = Self.safeFilename(name)
        let dir = directory.appendingPathComponent("pending/\(uuid)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(safe))
        return PendingAttachment.scheme + uuid + "/" + safe
    }

    nonisolated static func safeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var s = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        if s.hasPrefix(".") { s = "file" + s }
        return s.isEmpty ? "file" : String(s.prefix(80))
    }

    /// Lokale Datei eines Anhangs (lädt ihn bei Bedarf vom Server).
    func attachmentFile(note id: Int, path: String) async throws -> URL {
        let fm = FileManager.default
        if path.hasPrefix(PendingAttachment.scheme) {
            let rel = String(path.dropFirst(PendingAttachment.scheme.count))
            let url = directory.appendingPathComponent("pending/" + (rel.removingPercentEncoding ?? rel))
            if fm.fileExists(atPath: url.path) { return url }
            throw NotesError.http(404, path)
        }
        let id = resolve(id)
        let url = cacheURL(note: id, path: path)
        if fm.fileExists(atPath: url.path) { return url }
        guard id > 0 else { throw NotesError.http(404, path) }
        let decoded = path.removingPercentEncoding ?? path
        let data = try await client.attachment(note: id, path: decoded)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        return url
    }

    /// Anhang am Server löschen (ab Notes 6.1) und den Verweis aus der Notiz entfernen.
    func deleteAttachment(note id: Int, path: String) async {
        let id = resolve(id)
        if let i = idx(id) {
            let parts = MarkdownCodec.parse(notes[i].content)
            let cleaned = parts.map { p -> Paragraph in
                var q = p
                let m = NSMutableAttributedString(attributedString: p.text)
                var ranges: [NSRange] = []
                m.enumerateAttribute(.hnAttachment, in: NSRange(location: 0, length: m.length)) { v, r, _ in
                    if (v as? AttachmentRef)?.path == path { ranges.append(r) }
                }
                for r in ranges.reversed() { m.deleteCharacters(in: r) }
                q.text = m
                return q
            }
            updateContent(id, MarkdownCodec.serialize(cleaned))
        }
        if path.hasPrefix(PendingAttachment.scheme) { return }
        try? FileManager.default.removeItem(at: cacheURL(note: id, path: path))
        if id > 0, capabilities?.supportsAttachmentDelete ?? true {
            try? await client.deleteAttachment(note: id, path: path.removingPercentEncoding ?? path)
        }
    }

    private func cacheURL(note id: Int, path: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let key = (path.removingPercentEncoding ?? path).replacingOccurrences(of: "/", with: "__")
        return caches.appendingPathComponent("HomeNotes/\(client.accountKey)/att/\(id)/\(key)")
    }

    private func trashDir(_ id: UUID) -> URL { directory.appendingPathComponent("trash/\(id.uuidString)", isDirectory: true) }

    private func keepAttachments(of n: LocalNote, trashId: UUID) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        for (k, path) in MarkdownCodec.attachmentPaths(n.content).enumerated() {
            var src = cacheURL(note: n.id, path: path)
            if path.hasPrefix(PendingAttachment.scheme) {
                let rel = String(path.dropFirst(PendingAttachment.scheme.count))
                src = directory.appendingPathComponent("pending/" + (rel.removingPercentEncoding ?? rel))
            }
            guard fm.fileExists(atPath: src.path) else { continue }
            let dir = trashDir(trashId)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "\(k)-" + src.lastPathComponent
            if (try? fm.copyItem(at: src, to: dir.appendingPathComponent(name))) != nil { out[path] = name }
        }
        return out
    }

    // MARK: Abgleich

    private var now: Int { Int(Date().timeIntervalSince1970) }
    private func idx(_ id: Int) -> Int? { let id = resolve(id); return notes.firstIndex { $0.id == id } }

    private func changed() {
        scheduleSave()
        schedulePush()
    }

    /// Änderungen kurz sammeln, dann hochladen.
    func schedulePush(after seconds: Double = 1.5) {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            // eigener Task: ein laufendes Hochladen darf nie mittendrin abgebrochen werden
            Task { await self.push() }
        }
    }

    /// Voller Abgleich: erst eigene Änderungen hoch, dann Serverstand holen, dann Ordner/Erstellungsdaten per WebDAV.
    func sync() async {
        guard client.isSignedIn else { return }
        if isSyncing { syncAgain = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncAgain = false
            do {
                if capabilities == nil {
                    let caps = try await client.capabilities()
                    capabilities = caps
                    if let p = caps.notesPath { notesPath = p }
                    if let s = try? await client.settings() { notesPath = s.notesPath }
                }
                try await pushThrowing()
                try await pull()
                await loadDAV()
                purgeOldTrash()
                offline = false
                lastError = nil
                lastSync = Date()
            } catch let e as NotesError {
                offline = e.isOffline
                lastError = e.isOffline ? nil : e.localizedDescription
            } catch where Self.isCancellation(error) {
            } catch {
                lastError = error.localizedDescription
            }
            scheduleSave()
        } while syncAgain
    }

    private var pushing = false

    func push() async {
        do { try await pushThrowing(); offline = false }
        catch let e as NotesError { offline = e.isOffline; if !e.isOffline { lastError = e.localizedDescription } }
        catch where Self.isCancellation(error) {}
        catch { lastError = error.localizedDescription }
        scheduleSave()
    }

    nonisolated static func isCancellation(_ e: Error) -> Bool {
        e is CancellationError || (e as? URLError)?.code == .cancelled
    }

    private func pushThrowing() async throws {
        guard client.isSignedIn, !pushing else { return }
        pushing = true
        defer { pushing = false }
        for id in pendingDeletes {
            try await client.delete(id)
            pendingDeletes.remove(id)
        }
        // neue Notizen anlegen
        for n in notes where n.isLocalOnly && !n.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let title = titleFor(n.content)
            let hasPending = n.content.contains(PendingAttachment.scheme)
            var r: RemoteNote
            if n.createAttempted == true, let orphan = try await findCreated(n, title: title) {
                // Antwort auf ein früheres Anlegen ging verloren – die Notiz gibt es schon, nicht doppelt anlegen
                r = orphan
            } else {
                if let i = idx(n.id) { notes[i].createAttempted = true; saveNow() }
                r = try await client.create(title: title, content: hasPending ? "" : n.content, category: n.category,
                                            favorite: n.favorite, modified: n.modified)
            }
            guard let i = idx(n.id) else { continue }
            notes[i].createAttempted = nil
            idMap[n.id] = r.id
            for (k, v) in idMap where v == n.id { idMap[k] = r.id }
            let localContent = notes[i].content
            index.remove(n.id)
            notes[i].id = r.id
            notes[i].etag = r.etag
            notes[i].title = r.title ?? title
            notes[i].category = r.category ?? n.category
            notes[i].base = r.content ?? ""
            moveCache(from: n.id, to: r.id)
            // Inhalt inzwischen weitergeschrieben oder Anhänge offen → gleich als Änderung hochladen
            notes[i].dirtyContent = hasPending || localContent != (r.content ?? "")
            notes[i].dirtyMeta = notes[i].favorite != (r.favorite ?? false)
            reindex(notes[i])
            scheduleSave()
        }
        // Änderungen hochladen
        for n in notes where !n.isLocalOnly && (n.dirtyContent || n.dirtyMeta) {
            try await pushUpdate(n.id)
        }
    }

    private func pushUpdate(_ id: Int, attempt: Int = 0) async throws {
        guard let i0 = idx(id) else { return }
        var n = notes[i0]
        if n.dirtyContent, n.content.contains(PendingAttachment.scheme) {
            let uploaded = try await uploadPending(n)
            guard let i = idx(id) else { return }
            notes[i].content = notes[i].content.replacing(uploaded)
            n = notes[i]
            reindex(n)
        }
        let sentContent = n.content
        if n.dirtyContent { lastSent[n.id] = sentContent }
        do {
            let r = try await client.update(id: n.id, etag: n.etag,
                                            content: n.dirtyContent ? sentContent : nil,
                                            title: n.dirtyContent ? titleFor(sentContent) : nil,
                                            category: n.dirtyMeta ? n.category : nil,
                                            favorite: n.dirtyMeta ? n.favorite : nil)
            guard let i = idx(id) else { return }
            let cur = notes[i]                      // kann sich während des Hochladens geändert haben
            if let e = r.etag { notes[i].etag = e }
            if let t = r.title { notes[i].title = t }
            if let ro = r.readonly { notes[i].readonly = ro }
            if n.dirtyContent {
                notes[i].base = sentContent
                notes[i].dirtyContent = cur.content != sentContent
            }
            if n.dirtyMeta {
                let same = cur.category == n.category && cur.favorite == n.favorite
                notes[i].dirtyMeta = !same
                if same, let c = r.category { notes[i].category = c }     // vom Server bereinigter Name
            }
            reindex(notes[i])
            if notes[i].dirtyContent || notes[i].dirtyMeta { schedulePush(after: 0.5) }
        } catch NotesError.conflict(let server) {
            guard attempt < 3 else { throw NotesError.conflict(server) }
            let s: RemoteNote
            if let server, server.content != nil { s = server } else { s = try await client.note(id) }
            try await resolveConflict(id, server: s, attempt: attempt)
        } catch NotesError.http(404, _) {
            // am Server gelöscht, lokal geändert → als neue Notiz behalten
            guard let i = idx(id) else { return }
            notes[i].id = nextTempId; nextTempId -= 1
            notes[i].etag = nil
            reindex(notes[i])
        }
    }

    /// 412: Server-Stand ist neuer. Zeilenweise zusammenführen; geht das nicht, bleibt der Server-Stand in der Notiz und
    /// die eigene Fassung wird als Kopie angelegt (nichts geht verloren).
    private func resolveConflict(_ id: Int, server s: RemoteNote, attempt: Int) async throws {
        guard let i = idx(id) else { return }
        let local = notes[i]
        let theirs = s.content ?? ""
        if let sent = lastSent[id], sent == theirs, local.dirtyContent {
            // Der Server hat unseren letzten Stand schon (Antwort war verloren gegangen) – kein echter Konflikt
            notes[i].etag = s.etag
            notes[i].base = theirs
            notes[i].dirtyContent = local.content != theirs
            if notes[i].dirtyContent || notes[i].dirtyMeta { try await pushUpdate(id, attempt: attempt + 1) }
            return
        }
        if !local.dirtyContent || local.content == theirs {
            // nur Metadaten oder gleicher Inhalt: Server-ETag übernehmen und erneut senden
            let keep = (local.category, local.favorite, local.dirtyMeta)
            notes[i].adopt(s)
            notes[i].dirtyContent = false
            if keep.2 { notes[i].category = keep.0; notes[i].favorite = keep.1; notes[i].dirtyMeta = true }
            serverRevision += 1
            if notes[i].dirtyMeta { try await pushUpdate(id, attempt: attempt + 1) }
            return
        }
        if let merged = Merge3.merge(base: local.base ?? "", mine: local.content, theirs: theirs) {
            notes[i].etag = s.etag
            notes[i].base = theirs
            notes[i].content = merged
            notes[i].dirtyContent = true
            reindex(notes[i])
            serverRevision += 1
            try await pushUpdate(id, attempt: attempt + 1)
            return
        }
        // Konfliktkopie
        let copyTitle = titleFor(local.content) + " " + String(localized: "(Konflikt)")
        let r = try await client.create(title: copyTitle, content: local.content, category: local.category)
        var copy = LocalNote(remote: r)
        copy.created = now
        guard let j = idx(id) else { return }
        notes[j].adopt(s)
        notes[j].dirtyContent = false
        notes.append(copy)
        reindex(notes[j]); reindex(copy)
        serverRevision += 1
        lastError = String(localized: "„\(notes[j].displayTitle)“ wurde gleichzeitig woanders geändert – deine Fassung liegt als Kopie daneben.")
    }

    /// Nach verlorener Antwort: gleichnamige Notiz im selben Ordner, die noch keiner lokalen Notiz gehört.
    private func findCreated(_ n: LocalNote, title: String) async throws -> RemoteNote? {
        let known = Set(notes.map(\.id))
        let all = try await client.list().notes
        return all.first { r in
            !known.contains(r.id) && r.category == n.category && (r.title == title || (r.title ?? "").hasPrefix(title))
        }
    }

    private func uploadPending(_ n: LocalNote) async throws -> [String: String] {
        var map: [String: String] = [:]
        let refs = MarkdownCodec.attachmentPaths(n.content).filter { $0.hasPrefix(PendingAttachment.scheme) }
        for ref in Set(refs) {
            let rel = String(ref.dropFirst(PendingAttachment.scheme.count))
            let file = directory.appendingPathComponent("pending/" + (rel.removingPercentEncoding ?? rel))
            guard let data = try? Data(contentsOf: file) else { continue }
            let name = file.lastPathComponent
            let path = try await client.uploadAttachment(note: n.id, data: data, filename: name, mimeType: Self.mime(name))
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            map[ref] = encoded
            // gleich in den Cache, damit das Bild nicht erneut geladen wird
            let dst = cacheURL(note: n.id, path: encoded)
            try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.moveItem(at: file, to: dst)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        return map
    }

    nonisolated static func mime(_ name: String) -> String {
        switch name.split(separator: ".").last?.lowercased() ?? "" {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "heic": "image/heic"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "mov": "video/quicktime"
        case "mp4", "m4v": "video/mp4"
        case "m4a": "audio/mp4"
        case "txt", "md": "text/plain"
        default: "application/octet-stream"
        }
    }

    private func moveCache(from old: Int, to new: Int) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let base = caches.appendingPathComponent("HomeNotes/\(client.accountKey)/att")
        try? FileManager.default.moveItem(at: base.appendingPathComponent("\(old)"), to: base.appendingPathComponent("\(new)"))
    }

    private func titleFor(_ content: String) -> String {
        let t = MarkdownCodec.title(of: content)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        return t.isEmpty ? String(localized: "Neue Notiz") : t
    }

    private func pull() async throws {
        let prune = notes.isEmpty ? nil : lastModifiedHeader.map { $0 - 1 }
        let res = try await client.list(pruneBefore: prune)
        let serverIds = Set(res.notes.map(\.id))
        var changedAny = false
        for r in res.notes where !r.isPruned {
            if let i = notes.firstIndex(where: { $0.id == r.id }) {
                if notes[i].isDirty { continue }          // eigener Stand hat Vorrang, Konflikt löst der nächste Push
                if notes[i].etag == r.etag, r.content == nil || notes[i].content == r.content { continue }
                notes[i].adopt(r)
                reindex(notes[i])
                changedAny = true
            } else {
                let n = LocalNote(remote: r)
                notes.append(n)
                reindex(n)
                changedAny = true
            }
        }
        // am Server gelöscht
        for n in notes where !n.isLocalOnly && !serverIds.contains(n.id) && !pendingDeletes.contains(n.id) {
            guard let i = notes.firstIndex(where: { $0.id == n.id }) else { continue }
            if n.isDirty {
                notes[i].id = nextTempId; nextTempId -= 1; notes[i].etag = nil
                reindex(notes[i])
            } else {
                notes.remove(at: i); index.remove(n.id)
            }
            changedAny = true
        }
        // Volltext für Notizen ohne Inhalt nachladen (z. B. nach abgebrochenem erstem Abgleich)
        if res.lastModified != nil { lastModifiedHeader = res.lastModified }
        if changedAny { serverRevision += 1 }
    }

    private func loadDAV() async {
        guard let items = try? await client.davList(notesPath: notesPath) else { return }
        davFolders = Set(items.filter { $0.isFolder && !$0.path.split(separator: "/").contains { $0.hasPrefix(".") } }.map(\.path))
        let created = Dictionary(items.compactMap { i in i.fileId.flatMap { id in i.created.map { (id, $0) } } }, uniquingKeysWith: { a, _ in a })
        for i in notes.indices where notes[i].created == nil || notes[i].id > 0 {
            if let c = created[notes[i].id] { notes[i].created = c }
        }
    }

    private func purgeOldTrash() {
        let old = trash.filter { $0.daysLeft <= 0 }.map(\.id)
        if !old.isEmpty { purge(old) }
    }

    private func reindex(_ n: LocalNote) {
        index.update(id: n.id, title: n.displayTitle, text: MarkdownCodec.plainText(n.content) + " " + n.category)
    }

    // MARK: Speichern auf dem Gerät

    private struct CacheFile: Codable {
        var notes: [LocalNote]
        var trash: [TrashedNote]
        var davFolders: [String]
        var lastModified: Int?
        var nextTempId: Int
        var idMap: [Int: Int]
        var pendingDeletes: [Int]
        var notesPath: String
    }

    private var cacheFile: URL { directory.appendingPathComponent("cache.json") }

    private func load() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: cacheFile), let c = try? JSONDecoder().decode(CacheFile.self, from: data) else { return }
        notes = c.notes; trash = c.trash; davFolders = Set(c.davFolders); lastModifiedHeader = c.lastModified
        nextTempId = c.nextTempId; idMap = c.idMap; pendingDeletes = Set(c.pendingDeletes); notesPath = c.notesPath
        for n in notes { reindex(n) }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let c = CacheFile(notes: notes, trash: trash, davFolders: Array(davFolders), lastModified: lastModifiedHeader,
                          nextTempId: nextTempId, idMap: idMap, pendingDeletes: Array(pendingDeletes), notesPath: notesPath)
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Beim Abmelden: alles Lokale dieses Kontos löschen.
    func wipe() {
        pushTask?.cancel(); saveTask?.cancel()
        notes = []; trash = []; davFolders = []; pendingDeletes = []; idMap = [:]; lastModifiedHeader = nil
        capabilities = nil; index.removeAll()
        try? FileManager.default.removeItem(at: directory)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("HomeNotes/\(client.accountKey)"))
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Nach dem Anmelden mit einem anderen Konto neu laden.
    func reloadForAccount() {
        notes = []; trash = []; davFolders = []; pendingDeletes = []; idMap = [:]; lastModifiedHeader = nil
        capabilities = nil; index.removeAll(); offline = false; lastError = nil
        load()
    }

    func clearError() { lastError = nil }
}

private extension String {
    func replacing(_ map: [String: String]) -> String {
        var s = self
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }
}

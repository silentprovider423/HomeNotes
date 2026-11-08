import XCTest
@testable import HomeNotes

/// Tests gegen ein echtes Nextcloud-Testkonto. Zugang per Umgebung (nie im Code):
/// `TEST_RUNNER_NOTES_SERVER`, `TEST_RUNNER_NOTES_USER`, `TEST_RUNNER_NOTES_PASSWORD` an xcodebuild übergeben.
/// Alles, was ein Test anlegt, liegt in einem eigenen Ordner und wird am Ende wieder gelöscht.
@MainActor
final class Live {
    let client: NotesClient
    let folder = "HomeNotesTest-" + UUID().uuidString.prefix(8)
    var created: [Int] = []

    init() throws {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["NOTES_SERVER"], let u = env["NOTES_USER"], let p = env["NOTES_PASSWORD"], !s.isEmpty,
              let url = URL(string: s) else { throw XCTSkip("Kein Testkonto in der Umgebung") }
        client = NotesClient(server: url, user: u, password: p)
    }

    /// Alles Angelegte wieder entfernen.
    func cleanUp() async {
        for id in created { try? await client.delete(id) }
        let settings = try? await client.settings()
        try? await client.davDelete(notesPath: settings?.notesPath ?? "Notes", path: folder)
    }
}

final class LiveServerTests: XCTestCase {

    @MainActor
    func testCapabilities() async throws {
        let live = try Live()
        let client = live.client, folder = live.folder
        addTeardownBlock { @MainActor in await live.cleanUp() }
        let c = try await client.capabilities()
        XCTAssertTrue(c.isUsable)
        XCTAssertTrue(c.supportsAttachments)
        let uid = try await client.loadUserId()
        XCTAssertFalse(uid.isEmpty)
    }

    @MainActor
    func testCreateUpdateConflictDelete() async throws {
        let live = try Live()
        let client = live.client, folder = live.folder
        addTeardownBlock { @MainActor in await live.cleanUp() }
        let n = try await client.create(title: "Test", content: "# Test\nZeile", category: folder)
        live.created.append(n.id)
        XCTAssertEqual(n.category, folder)
        let u = try await client.update(id: n.id, etag: n.etag, content: "# Test\nZeile 2", title: "Test")
        XCTAssertNotEqual(u.etag, n.etag)
        // veralteter ETag → 412 mit Serverstand
        do {
            _ = try await client.update(id: n.id, etag: n.etag, content: "überschreiben?")
            XCTFail("Konflikt erwartet")
        } catch NotesError.conflict(let server) {
            XCTAssertEqual(server?.content, "# Test\nZeile 2")
        }
        // Liste mit pruneBefore: unveränderte Notiz nur als ID
        let all = try await client.list()
        XCTAssertTrue(all.notes.contains { $0.id == n.id && $0.content == "# Test\nZeile 2" })
        if let lm = all.lastModified {
            let pruned = try await client.list(pruneBefore: lm + 10)
            XCTAssertTrue(pruned.notes.first { $0.id == n.id }?.isPruned ?? false)
        }
        try await client.delete(n.id)
        live.created.removeAll()
        do { _ = try await client.note(n.id); XCTFail("gelöscht erwartet") } catch NotesError.http(404, _) {}
    }

    @MainActor
    func testAttachments() async throws {
        let live = try Live()
        let client = live.client, folder = live.folder
        addTeardownBlock { @MainActor in await live.cleanUp() }
        let n = try await client.create(title: "Bild", content: "Bild", category: folder)
        live.created.append(n.id)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { c in
            UIColor.orange.setFill(); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let path = try await client.uploadAttachment(note: n.id, data: png, filename: "probe.png", mimeType: "image/png")
        XCTAssertTrue(path.hasSuffix(".png"))
        let back = try await client.attachment(note: n.id, path: path)
        XCTAssertEqual(back, png)
        try await client.deleteAttachment(note: n.id, path: path)
        do { _ = try await client.attachment(note: n.id, path: path); XCTFail("gelöscht erwartet") } catch NotesError.http(404, _) {}
    }

    @MainActor
    func testFoldersViaWebDAV() async throws {
        let live = try Live()
        let client = live.client, folder = live.folder
        addTeardownBlock { @MainActor in await live.cleanUp() }
        let notesPath = try await client.settings().notesPath
        try await client.davMakeFolder(notesPath: notesPath, folder: folder + "/Unter")
        var items = try await client.davList(notesPath: notesPath)
        XCTAssertTrue(items.contains { $0.isFolder && $0.path == folder + "/Unter" })
        try await client.davMove(notesPath: notesPath, from: folder + "/Unter", to: folder + "/Neu")
        items = try await client.davList(notesPath: notesPath)
        XCTAssertTrue(items.contains { $0.path == folder + "/Neu" })
        XCTAssertFalse(items.contains { $0.path == folder + "/Unter" })
    }

    @MainActor
    func testLoginFlowStart() async throws {
        let live = try Live()
        let client = live.client, folder = live.folder
        addTeardownBlock { @MainActor in await live.cleanUp() }
        let s = try await LoginFlow.start(client.server!.absoluteString)
        XCTAssertEqual(s.login.host(), client.server!.host())
    }

    /// Ganzer Abgleich: offline anlegen, hochladen, gleichzeitige Änderung zusammenführen, Konfliktkopie, löschen.
    @MainActor
    func testStoreSyncMergeAndConflictCopy() async throws {
        let live = try Live()
        let client = live.client, folder = live.folder
        addTeardownBlock { @MainActor in await live.cleanUp() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NoteStore(client: client, directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. lokal anlegen → hochladen
        let tmp = store.createNote(category: folder)
        store.updateContent(tmp, "# Sync\nZeile 1\nZeile 2\nZeile 3")
        await store.sync()
        let id = store.resolve(tmp)
        XCTAssertGreaterThan(id, 0)
        live.created.append(id)
        let v93 = try await client.note(id).content
        XCTAssertEqual(v93, "# Sync\nZeile 1\nZeile 2\nZeile 3")
        XCTAssertTrue(store.folders.contains(folder))

        // 2. gleichzeitig: Server ändert Zeile 3, lokal Zeile 1 → zusammenführen
        let s = try await client.note(id)
        _ = try await client.update(id: id, etag: s.etag, content: "# Sync\nZeile 1\nZeile 2\nZeile DREI")
        store.updateContent(id, "# Sync\nZeile EINS\nZeile 2\nZeile 3")
        await store.sync()
        let v94 = try await client.note(id).content
        XCTAssertEqual(v94, "# Sync\nZeile EINS\nZeile 2\nZeile DREI")
        XCTAssertEqual(store.note(id)?.content, "# Sync\nZeile EINS\nZeile 2\nZeile DREI")

        // 3. gleiche Zeile verschieden geändert → Server-Stand bleibt, eigene Fassung als Kopie
        let s2 = try await client.note(id)
        _ = try await client.update(id: id, etag: s2.etag, content: "# Sync\nServer\nZeile 2\nZeile DREI")
        store.updateContent(id, "# Sync\nLokal\nZeile 2\nZeile DREI")
        await store.sync()
        let inFolder = try await client.list().notes.filter { $0.category == folder }
        live.created += inFolder.map(\.id).filter { $0 != id }
        XCTAssertEqual(inFolder.count, 2)
        XCTAssertTrue(inFolder.contains { $0.content == "# Sync\nServer\nZeile 2\nZeile DREI" })
        XCTAssertTrue(inFolder.contains { $0.content == "# Sync\nLokal\nZeile 2\nZeile DREI" })
        store.clearError()

        // 4. Anpinnen + Bewegen
        store.setFavorite([id], true)
        try await store.createFolder(folder + "/Ziel")
        store.move([id], to: folder + "/Ziel")
        await store.sync()
        let moved = try await client.note(id)
        XCTAssertEqual(moved.favorite, true)
        XCTAssertEqual(moved.category, folder + "/Ziel")

        // 5. Anhang offline vormerken, beim Abgleich hochladen
        let ref = try store.addAttachment(data: Data("hallo".utf8), filename: "notiz.txt")
        store.updateContent(id, (store.note(id)?.content ?? "") + "\n[notiz](\(ref))")
        await store.sync()
        let withAtt = try await client.note(id).content ?? ""
        XCTAssertFalse(withAtt.contains(PendingAttachment.scheme))
        XCTAssertTrue(withAtt.contains(".attachments.\(id)/"))

        // 6. Löschen → Zuletzt gelöscht → wiederherstellen (neue ID)
        store.delete([id])
        await store.sync()
        live.created.removeAll { $0 == id }
        XCTAssertEqual(store.trash.first?.originalId, id)
        store.restore([store.trash[0].id])
        await store.sync()
        let restored = store.notes.first { $0.content.hasPrefix("# Sync\nServer") && $0.category == folder + "/Ziel" }
        XCTAssertNotNil(restored)
        XCTAssertGreaterThan(restored?.id ?? 0, 0)
        if let r = restored { live.created.append(r.id) }

        // 7. Ordner umbenennen per WebDAV: Notizen behalten ihre ID
        try await store.renameFolder(folder + "/Ziel", to: "Umbenannt")
        if let r = restored {
            let v928 = try await client.note(r.id).category
            XCTAssertEqual(v928, folder + "/Umbenannt")
        }
    }
}

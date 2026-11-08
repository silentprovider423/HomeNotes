import SwiftUI

struct SettingsView: View {
    @Environment(NoteStore.self) private var store
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sort") private var sortRaw = NoteSort.modified.rawValue
    @AppStorage("groupByDate") private var groupByDate = true
    @AppStorage("newNoteStyle") private var newNoteStyle = BlockKind.title.rawValue
    @AppStorage("showCounts") private var showCounts = true
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Server", value: NotesClient.shared.server?.host() ?? "–")
                    LabeledContent("Benutzer", value: NotesClient.shared.user ?? "–")
                    if let c = store.capabilities {
                        LabeledContent("Nextcloud Notes", value: c.version)
                        LabeledContent("Anhänge", value: c.supportsAttachments ? String(localized: "verfügbar") : String(localized: "nicht verfügbar"))
                    }
                    if let d = store.lastSync {
                        LabeledContent("Zuletzt abgeglichen", value: d.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Jetzt abgleichen") { Task { await store.sync() } }.disabled(store.isSyncing)
                }
                Section("Notizen") {
                    Picker("Notizen sortieren nach", selection: $sortRaw) {
                        Text("Bearbeitungsdatum").tag(NoteSort.modified.rawValue)
                        Text("Erstellungsdatum").tag(NoteSort.created.rawValue)
                        Text("Titel").tag(NoteSort.title.rawValue)
                    }
                    Toggle("Nach Datum gruppieren", isOn: $groupByDate)
                    Picker("Neue Notizen beginnen mit", selection: $newNoteStyle) {
                        Text("Titel").tag(BlockKind.title.rawValue)
                        Text("Überschrift").tag(BlockKind.heading.rawValue)
                        Text("Unterüberschrift").tag(BlockKind.subheading.rawValue)
                        Text("Text").tag(BlockKind.body.rawValue)
                    }
                    Toggle("Notizenanzahl einblenden", isOn: $showCounts)
                }
                Section {
                    Button("Abmelden", role: .destructive) { confirmSignOut = true }
                } footer: {
                    Text("Notizen werden als Markdown-Dateien in deiner Nextcloud gespeichert (App „Notes“) und auf diesem iPhone zwischengespeichert, damit sie auch ohne Verbindung da sind.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .alert("Abmelden?", isPresented: $confirmSignOut) {
                Button("Abmelden", role: .destructive) {
                    Task {
                        await store.push()
                        store.wipe()
                        await NotesClient.shared.signOut()
                        router.path = [.folder(.all)]
                        session.signedIn = false
                        dismiss()
                    }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: { Text("Die Notizen bleiben in deiner Nextcloud. Auf diesem iPhone wird der Zwischenspeicher gelöscht.") }
        }
    }
}

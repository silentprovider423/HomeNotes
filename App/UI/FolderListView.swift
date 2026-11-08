import SwiftUI

/// Ordnerliste wie in Apples Notizen: Alle Notizen, Notizen (ohne Ordner), eigene Ordner mit Unterordnern, Zuletzt gelöscht.
struct FolderListView: View {
    @Environment(NoteStore.self) private var store
    @Environment(Router.self) private var router
    @AppStorage("showCounts") private var showCounts = true
    @State private var search = ""
    @State private var newFolder: NewFolderRequest?
    @State private var folderName = ""
    @State private var rename: String?
    @State private var renameText = ""
    @State private var deleteFolder: String?
    @State private var showSettings = false
    @State private var error: String?

    struct NewFolderRequest: Identifiable { let id = UUID(); let parent: String }

    var body: some View {
        List {
            if !search.isEmpty {
                SearchResultsSection(query: search, folder: .all)
            } else {
                Section {
                    folderRow(.all, String(localized: "Alle Notizen"), icon: "tray.full")
                        .accessibilityIdentifier("folder.all")
                    folderRow(.category(""), String(localized: "Notizen"), icon: "folder")
                        .accessibilityIdentifier("folder.notes")
                    ForEach(store.children(of: ""), id: \.self) { f in
                        FolderTreeRow(path: f, showCounts: showCounts, actions: actions)
                    }
                    if !store.trash.isEmpty {
                        folderRow(.trash, String(localized: "Zuletzt gelöscht"), icon: "trash")
                            .accessibilityIdentifier("folder.trash")
                    }
                } header: {
                    Text(accountTitle).font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ordner")
        .searchable(text: $search, prompt: Text("Suchen"))
        .refreshable { await store.sync() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $showCounts) { Label("Notizenanzahl einblenden", systemImage: "number") }
                    Button { showSettings = true } label: { Label("Einstellungen", systemImage: "gear") }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(Text("Mehr"))
            }
            ToolbarItem(placement: .bottomBar) {
                Button { folderName = ""; newFolder = NewFolderRequest(parent: "") } label: { Image(systemName: "folder.badge.plus") }
                    .accessibilityLabel(Text("Neuer Ordner"))
                    .accessibilityIdentifier("newFolder")
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { NewNoteButton(category: "") }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("Neuer Ordner", isPresented: Binding(get: { newFolder != nil }, set: { if !$0 { newFolder = nil } })) {
            TextField("Name", text: $folderName).accessibilityIdentifier("folderName")
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern") {
                let parent = newFolder?.parent ?? ""
                let name = folderName.replacingOccurrences(of: "/", with: "-")
                run { try await store.createFolder(parent.isEmpty ? name : parent + "/" + name) }
            }
        } message: {
            if let p = newFolder?.parent, !p.isEmpty { Text("Unterordner von „\(p)“") } else { Text("Gib einen Namen für diesen Ordner ein.") }
        }
        .alert("Ordner umbenennen", isPresented: Binding(get: { rename != nil }, set: { if !$0 { rename = nil } })) {
            TextField("Name", text: $renameText)
            Button("Abbrechen", role: .cancel) {}
            Button("Sichern") { if let r = rename { let t = renameText; run { try await store.renameFolder(r, to: t) } } }
        }
        .alert("Ordner löschen?", isPresented: Binding(get: { deleteFolder != nil }, set: { if !$0 { deleteFolder = nil } })) {
            Button("Ordner löschen", role: .destructive) { if let f = deleteFolder { run { try await store.deleteFolder(f) } } }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Alle Notizen und Unterordner werden gelöscht. Die Notizen bleiben 30 Tage in „Zuletzt gelöscht“.") }
        .alert("Fehler", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private var accountTitle: String {
        "Nextcloud"      // wie Apples „iCloud“-Abschnitt (Server-Adresse steht in den Einstellungen)
    }

    private var actions: FolderActions {
        FolderActions(
            newSub: { p in folderName = ""; newFolder = NewFolderRequest(parent: p) },
            rename: { p in renameText = p.split(separator: "/").last.map(String.init) ?? p; rename = p },
            delete: { p in deleteFolder = p })
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() }
            catch { self.error = (error as? NotesError)?.isOffline == true
                ? String(localized: "Ordner lassen sich nur mit Verbindung zum Server ändern.") : error.localizedDescription }
        }
    }

    private func folderRow(_ f: FolderID, _ title: String, icon: String) -> some View {
        NavigationLink(value: Route.folder(f)) {
            FolderLabel(title: title, icon: icon, count: showCounts ? store.count(f) : nil)
        }
    }
}

struct FolderActions {
    var newSub: (String) -> Void
    var rename: (String) -> Void
    var delete: (String) -> Void
}

struct FolderLabel: View {
    let title: String
    let icon: String
    let count: Int?
    var body: some View {
        HStack {
            Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(Color.accentColor) }
            Spacer()
            if let count { Text("\(count)").foregroundStyle(.secondary) }
        }
    }
}

/// Ordner mit aufklappbaren Unterordnern.
struct FolderTreeRow: View {
    let path: String
    let showCounts: Bool
    let actions: FolderActions
    @Environment(NoteStore.self) private var store
    @Environment(Router.self) private var router
    @AppStorage("expandedFolders") private var expandedRaw = ""

    private var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    var body: some View {
        let kids = store.children(of: path)
        Group {
            if kids.isEmpty {
                NavigationLink(value: Route.folder(.category(path))) { label }
            } else {
                DisclosureGroup(isExpanded: expanded) {
                    ForEach(kids, id: \.self) { k in AnyView(FolderTreeRow(path: k, showCounts: showCounts, actions: actions)) }
                } label: {
                    Button { router.path.append(.folder(.category(path))) } label: { label }
                        .foregroundStyle(.primary)
                }
            }
        }
        .accessibilityIdentifier("folder.\(path)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { actions.delete(path) } label: { Label("Löschen", systemImage: "trash") }.tint(.red)
            Button { actions.rename(path) } label: { Label("Umbenennen", systemImage: "pencil") }.tint(.indigo)
        }
        .contextMenu {
            Button { actions.rename(path) } label: { Label("Ordner umbenennen", systemImage: "pencil") }
            Button { actions.newSub(path) } label: { Label("Neuer Unterordner", systemImage: "folder.badge.plus") }
            Button(role: .destructive) { actions.delete(path) } label: { Label("Ordner löschen", systemImage: "trash") }
        }
    }

    private var label: some View {
        FolderLabel(title: name, icon: "folder", count: showCounts ? store.count(.category(path)) : nil)
    }

    private var expanded: Binding<Bool> {
        Binding(get: { expandedRaw.split(separator: "\n").contains { $0 == path } },
                set: { on in
                    var set = Set(expandedRaw.split(separator: "\n").map(String.init))
                    if on { set.insert(path) } else { set.remove(path) }
                    expandedRaw = set.sorted().joined(separator: "\n")
                })
    }
}

/// Suchergebnisse (lokaler Volltextindex).
struct SearchResultsSection: View {
    let query: String
    let folder: FolderID
    @Environment(NoteStore.self) private var store

    var body: some View {
        let hits = store.search(query, in: folder)
        let top = hits.prefix(3).filter { SearchIndex.tokens($0.displayTitle).contains { t in SearchIndex.tokens(query).allSatisfy { t.hasPrefix($0) } } }
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            if !top.isEmpty, hits.count > 3 {
                Section("Toptreffer") { ForEach(top) { NoteLinkRow(note: $0, showFolder: true) } }
            }
            Section(hits.count == 1 ? String(localized: "1 Notiz gefunden") : String(localized: "\(hits.count) Notizen gefunden")) {
                ForEach(hits) { NoteLinkRow(note: $0, showFolder: true, highlight: query) }
            }
        }
    }
}

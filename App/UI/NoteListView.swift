import SwiftUI

/// Notizliste eines Ordners: „Angepinnt“ oben, dann nach Datum gruppiert (Heute, Gestern, Vorherige 7/30 Tage, Monate, Jahre).
struct NoteListView: View {
    let folder: FolderID
    @Environment(NoteStore.self) private var store
    @Environment(Router.self) private var router
    @AppStorage("sort") private var sortRaw = NoteSort.modified.rawValue
    @AppStorage("ascending") private var ascending = false
    @AppStorage("groupByDate") private var groupByDate = true
    @State private var search = ""
    @State private var selection = Set<Int>()
    @State private var editMode = EditMode.inactive
    @State private var trashSelection = Set<UUID>()
    @State private var moveIds: [Int]?
    @State private var confirmDeleteSelected = false
    @State private var confirmEmptyTrash = false
    @State private var pinnedCollapsed = false

    private var sort: NoteSort { NoteSort(rawValue: sortRaw) ?? .modified }
    private var isTrash: Bool { folder == .trash }

    private var title: String {
        switch folder {
        case .all: String(localized: "Alle Notizen")
        case .category(let c): c.isEmpty ? String(localized: "Notizen") : (c.split(separator: "/").last.map(String.init) ?? c)
        case .trash: String(localized: "Zuletzt gelöscht")
        }
    }

    private var subtitle: String {
        let n = store.count(folder)
        var s = n == 1 ? String(localized: "1 Notiz") : String(localized: "\(n) Notizen")
        if store.offline { s += " · " + String(localized: "Offline") }
        return s
    }

    var body: some View {
        List(selection: isTrash ? nil : $selection) {
            if isTrash { trashContent }
            else if !search.isEmpty { SearchResultsSection(query: search, folder: folder) }
            else { notesContent }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .searchable(text: $search, prompt: Text("Suchen"))
        .refreshable { await store.sync() }
        .toolbar { toolbar }
        .overlay {
            if !isTrash, search.isEmpty, store.notes(in: folder).isEmpty {
                ContentUnavailableView("Keine Notizen", systemImage: "note.text", description: Text("Tippe auf „Neue Notiz“, um eine zu beginnen."))
            } else if isTrash, store.trash.isEmpty {
                ContentUnavailableView("Keine Notizen", systemImage: "trash")
            }
        }
        .sheet(isPresented: Binding(get: { moveIds != nil }, set: { if !$0 { moveIds = nil } })) {
            MoveNotesSheet(ids: moveIds ?? [], current: folder.categoryValue) { selection = []; editMode = .inactive }
        }
        .alert(selection.count == 1 ? "Notiz löschen?" : "\(selection.count) Notizen löschen?", isPresented: $confirmDeleteSelected) {
            Button("Löschen", role: .destructive) {
                store.delete(Array(selection)); selection = []; editMode = .inactive
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Gelöschte Notizen bleiben 30 Tage in „Zuletzt gelöscht“.") }
        .alert("Alle Notizen endgültig löschen?", isPresented: $confirmEmptyTrash) {
            Button("Alle löschen", role: .destructive) { store.purge(store.trash.map(\.id)) }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Das kann nicht widerrufen werden.") }
    }

    // MARK: Inhalt

    @ViewBuilder
    private var notesContent: some View {
        let all = store.sorted(store.notes(in: folder), by: sort, ascending: ascending)
        let pinned = all.filter(\.favorite)
        let rest = all.filter { !$0.favorite }
        if !pinned.isEmpty {
            Section(isExpanded: Binding(get: { !pinnedCollapsed }, set: { pinnedCollapsed = !$0 })) {
                ForEach(pinned) { row($0) }
            } header: {
                Label("Angepinnt", systemImage: "pin.fill").font(.headline).foregroundStyle(.primary).textCase(nil)
            }
        }
        if groupByDate && sort != .title {
            ForEach(DateGroup.group(rest, by: sort), id: \.title) { g in
                Section {
                    ForEach(g.notes) { row($0) }
                } header: {
                    Text(g.title).font(.headline).foregroundStyle(.primary).textCase(nil)
                }
            }
        } else if !rest.isEmpty {
            Section(pinned.isEmpty ? "" : String(localized: "Notizen")) { ForEach(rest) { row($0) } }
        }
    }

    private func row(_ n: LocalNote) -> some View {
        NoteLinkRow(note: n, showFolder: folder == .all)
            .tag(n.id)
    }

    @ViewBuilder
    private var trashContent: some View {
        if !store.trash.isEmpty {
            Section {
                ForEach(store.trash) { t in
                    NavigationLink(value: Route.trashNote(t.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.displayTitle).font(.headline).lineLimit(1)
                            Text(t.daysLeft == 1 ? String(localized: "Noch 1 Tag") : String(localized: "Noch \(t.daysLeft) Tage"))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.purge([t.id]) } label: { Label("Löschen", systemImage: "trash") }.tint(.red)
                        Button { store.restore([t.id]) } label: { Label("Wiederherstellen", systemImage: "arrow.uturn.backward") }.tint(.indigo)
                    }
                    .contextMenu {
                        Button { store.restore([t.id]) } label: { Label("Wiederherstellen", systemImage: "arrow.uturn.backward") }
                        Button(role: .destructive) { store.purge([t.id]) } label: { Label("Endgültig löschen", systemImage: "trash") }
                    }
                }
            } header: {
                Text("Notizen sind bis zu 30 Tage lang verfügbar. Danach werden sie endgültig gelöscht.")
                    .font(.footnote).textCase(nil)
            }
        }
    }

    // MARK: Symbolleisten

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isTrash {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Alle löschen", role: .destructive) { confirmEmptyTrash = true }.disabled(store.trash.isEmpty)
            }
        } else if editMode.isEditing {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Fertig") { editMode = .inactive; selection = [] }.buttonStyle(.glassProminent)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(selection.isEmpty ? "Alle bewegen" : "Bewegen") {
                    moveIds = selection.isEmpty ? store.notes(in: folder).map(\.id) : Array(selection)
                }
                .disabled(store.notes(in: folder).isEmpty)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(selection.isEmpty ? "Alle löschen" : "Löschen", role: .destructive) {
                    if selection.isEmpty { selection = Set(store.notes(in: folder).map(\.id)) }
                    confirmDeleteSelected = true
                }
                .disabled(store.notes(in: folder).isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { NewNoteButton(category: folder.categoryValue ?? "") }
        }
    }

    private var moreMenu: some View {
        Menu {
            Button { withAnimation { editMode = .active } } label: { Label("Notizen auswählen", systemImage: "checkmark.circle") }
            Section {
                Menu {
                    Picker("Sortieren nach", selection: $sortRaw) {
                        Text("Bearbeitungsdatum").tag(NoteSort.modified.rawValue)
                        Text("Erstellungsdatum").tag(NoteSort.created.rawValue)
                        Text("Titel").tag(NoteSort.title.rawValue)
                    }
                    Picker("Reihenfolge", selection: $ascending) {
                        Text(sort == .title ? "A–Z" : "Neueste zuerst").tag(sort == .title)
                        Text(sort == .title ? "Z–A" : "Älteste zuerst").tag(sort != .title)
                    }
                } label: {
                    Label("Sortieren nach", systemImage: "arrow.up.arrow.down")
                    Text(sortName)
                }
                Toggle(isOn: $groupByDate) { Label("Nach Datum gruppieren", systemImage: "calendar") }
                    .disabled(sort == .title)
            }
        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel(Text("Mehr"))
        .accessibilityIdentifier("listMore")
    }

    private var sortName: String {
        switch sort {
        case .modified: String(localized: "Bearbeitungsdatum")
        case .created: String(localized: "Erstellungsdatum")
        case .title: String(localized: "Titel")
        }
    }
}

extension FolderID {
    var categoryValue: String? { if case .category(let c) = self { return c }; return nil }
}

/// Zeile mit Wischaktionen und Kontextmenü (Anpinnen, Teilen, Bewegen, Löschen).
struct NoteLinkRow: View {
    let note: LocalNote
    var showFolder = false
    var highlight: String?
    @Environment(NoteStore.self) private var store
    @State private var share: ShareItem?
    @State private var move = false

    var body: some View {
        NavigationLink(value: Route.note(note.id)) {
            NoteRow(note: note, showFolder: showFolder, highlight: highlight)
        }
        .accessibilityIdentifier("note.\(note.displayTitle)")
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { store.setFavorite([note.id], !note.favorite) } label: {
                Label(note.favorite ? "Loslösen" : "Anpinnen", systemImage: note.favorite ? "pin.slash.fill" : "pin.fill")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !note.readonly {
                Button(role: .destructive) { withAnimation { store.delete([note.id]) } } label: { Label("Löschen", systemImage: "trash.fill") }.tint(.red)
                Button { move = true } label: { Label("Bewegen", systemImage: "folder.fill") }.tint(.indigo)
            }
            Button { share = ShareItem(text: note.content) } label: { Label("Teilen", systemImage: "square.and.arrow.up.fill") }.tint(.blue)
        }
        .contextMenu {
            Button { store.setFavorite([note.id], !note.favorite) } label: {
                Label(note.favorite ? "Notiz loslösen" : "Notiz anpinnen", systemImage: note.favorite ? "pin.slash" : "pin")
            }
            Button { share = ShareItem(text: note.content) } label: { Label("Kopie senden", systemImage: "square.and.arrow.up") }
            if !note.readonly {
                Button { move = true } label: { Label("Bewegen", systemImage: "folder") }
                Button(role: .destructive) { store.delete([note.id]) } label: { Label("Löschen", systemImage: "trash") }
            }
        } preview: {
            NotePreviewCard(note: note)
        }
        .sheet(item: $share) { s in ActivityView(items: [s.text]).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $move) { MoveNotesSheet(ids: [note.id], current: note.category) }
    }
}

struct NoteRow: View {
    let note: LocalNote
    var showFolder = false
    var highlight: String?
    @Environment(NoteStore.self) private var store

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Self.rowDate(note.modifiedDate)).foregroundStyle(.primary.opacity(0.75))
                    Text(note.preview.isEmpty ? String(localized: "Kein weiterer Text") : note.preview)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.subheadline)
                if showFolder {
                    Label(folderName, systemImage: "folder").font(.subheadline).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
            }
            Spacer(minLength: 0)
            if let p = note.firstImagePath { Thumbnail(noteId: note.id, path: p) }
            if note.isDirty { Image(systemName: "icloud.and.arrow.up").font(.caption).foregroundStyle(.tertiary).accessibilityLabel(Text("Noch nicht gesichert")) }
        }
        .padding(.vertical, 2)
    }

    private var folderName: String {
        note.category.isEmpty ? String(localized: "Notizen") : (note.category.split(separator: "/").last.map(String.init) ?? note.category)
    }

    /// Wie Apple: heute Uhrzeit, gestern „Gestern“, diese Woche Wochentag, sonst Datum.
    static func rowDate(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return String(localized: "Gestern") }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(date: .numeric, time: .omitted)
    }
}

struct Thumbnail: View {
    let noteId: Int
    let path: String
    @Environment(NoteStore.self) private var store
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Color(.secondarySystemFill) }
        }
        .frame(width: 44, height: 44)
        .clipShape(.rect(cornerRadius: 6))
        .task(id: path) {
            guard let url = try? await store.attachmentFile(note: noteId, path: path) else { return }
            image = await Task.detached { AttachmentViews.downsample(url, maxPixel: 140) }.value
        }
    }
}

/// Vorschau beim langen Drücken.
struct NotePreviewCard: View {
    let note: LocalNote
    var body: some View {
        let paras = MarkdownCodec.parse(note.content).prefix(18)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(paras.enumerated()), id: \.offset) { _, p in
                let text = p.table.map { $0.rows.map { $0.joined(separator: " · ") }.joined(separator: "\n") } ?? p.text.string.replacingOccurrences(of: "\u{FFFC}", with: "🖼")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    switch p.kind {
                    case .check: Image(systemName: p.checked ? "checkmark.circle.fill" : "circle").foregroundStyle(p.checked ? Color.accentColor : .secondary)
                    case .bullet: Text("•")
                    case .dash: Text("–")
                    case .number: Text("·")
                    default: EmptyView()
                    }
                    Text(text).font(font(p.kind))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 340, height: 420, alignment: .topLeading)
        .background(Color(.systemBackground))
    }

    private func font(_ k: BlockKind) -> Font {
        switch k {
        case .title: .title.bold()
        case .heading: .title2.bold()
        case .subheading: .title3.weight(.semibold)
        case .mono: .body.monospaced()
        default: .body
        }
    }
}

/// Datumsgruppen wie Apple.
enum DateGroup {
    struct G { let title: String; var notes: [LocalNote] }

    static func group(_ notes: [LocalNote], by sort: NoteSort) -> [G] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [G] = []
        for n in notes {
            let d = sort == .created ? (n.createdDate ?? n.modifiedDate) : n.modifiedDate
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: today).day ?? 0
            let title: String
            if days <= 0 { title = String(localized: "Heute") }
            else if days == 1 { title = String(localized: "Gestern") }
            else if days <= 7 { title = String(localized: "Vorherige 7 Tage") }
            else if days <= 30 { title = String(localized: "Vorherige 30 Tage") }
            else if cal.component(.year, from: d) == cal.component(.year, from: today) { title = d.formatted(.dateTime.month(.wide)) }
            else { title = String(cal.component(.year, from: d)) }
            if let i = out.firstIndex(where: { $0.title == title }) { out[i].notes.append(n) }
            else { out.append(G(title: title, notes: [n])) }
        }
        return out
    }
}

/// „Notiz bewegen“: Ordner wählen (auch neuen anlegen).
struct MoveNotesSheet: View {
    let ids: [Int]
    let current: String?
    var done: () -> Void = {}
    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var askNew = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    target("", name: String(localized: "Notizen"), depth: 0)
                    ForEach(store.folders, id: \.self) { f in
                        target(f, name: f.split(separator: "/").last.map(String.init) ?? f, depth: f.split(separator: "/").count)
                    }
                } header: { Text(verbatim: "Nextcloud").textCase(nil) }
            }
            .navigationTitle(ids.count == 1 ? String(localized: "Notiz bewegen") : String(localized: "\(ids.count) Notizen bewegen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    Button { newName = ""; askNew = true } label: { Label("Neuer Ordner", systemImage: "folder.badge.plus") }
                }
            }
            .alert("Neuer Ordner", isPresented: $askNew) {
                TextField("Name", text: $newName)
                Button("Abbrechen", role: .cancel) {}
                Button("Sichern") {
                    let name = newName.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task {
                        do { try await store.createFolder(name) } catch { /* ohne Server: Ordner entsteht mit der Notiz */ }
                        store.move(ids, to: name); done(); dismiss()
                    }
                }
            }
        }
    }

    private func target(_ path: String, name: String, depth: Int) -> some View {
        Button {
            store.move(ids, to: path); done(); dismiss()
        } label: {
            HStack {
                Image(systemName: "folder").foregroundStyle(Color.accentColor)
                Text(name).foregroundStyle(path == current ? .secondary : .primary)
                Spacer()
                Text("\(store.count(.category(path)))").foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(max(0, depth - 1)) * 18)
        }
        .disabled(path == current)
        .accessibilityIdentifier("move.\(path.isEmpty ? "Notizen" : path)")
    }
}

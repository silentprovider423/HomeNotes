import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

struct EditorTextView: UIViewRepresentable {
    let controller: EditorController
    func makeUIView(context: Context) -> NoteTextView { controller.textView }
    func updateUIView(_ uiView: NoteTextView, context: Context) {}
}

/// Notiz-Editor: Text wie in Apples Notizen, oben Teilen und „…“, unten bzw. über der Tastatur die Werkzeuge.
struct NoteEditorView: View {
    let noteId: Int
    var readonlyContent: String?           // Vorschau aus „Zuletzt gelöscht“
    var trashId: UUID?
    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newNoteStyle") private var newNoteStyle = BlockKind.title.rawValue
    @State private var editor = EditorController()
    @State private var router = AttachRouter.shared
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotos = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var showMove = false
    @State private var confirmDelete = false
    @State private var attachError: String?
    @State private var loaded = false

    private var note: LocalNote? { store.note(noteId) }
    private var isTrash: Bool { readonlyContent != nil }

    var body: some View {
        EditorTextView(controller: editor)
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .toolbar(editor.isEditing ? .hidden : .visible, for: .bottomBar)
            .onAppear(perform: setUp)
            .onDisappear {
                editor.flush()
                if !isTrash { store.discardIfEmpty(noteId) }
                store.schedulePush(after: 0.2)
            }
            .onChange(of: store.serverRevision) {
                if let n = note, !isTrash { editor.reloadIfChanged(markdown: n.content, modified: n.modifiedDate) }
            }
            .onChange(of: router.pending) {
                guard let s = router.pending else { return }
                router.pending = nil
                attach(s)
            }
            .sheet(item: $editor.tableEdit) { e in
                TableEditorSheet(table: e.original) { result, toText in
                    editor.applyTable(original: e.original, result: result, convertToText: toText)
                }
            }
            .sheet(item: $editor.linkEdit) { e in LinkEditorSheet(edit: e) { editor.applyLink($0, remove: $1) } }
            .sheet(isPresented: $showMove) {
                MoveNotesSheet(ids: [store.resolve(noteId)], current: note?.category)
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker { data, name in addAttachment(data, name) }.ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
            .onChange(of: photoItems) { Task { await importPhotos() } }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                importFiles(result)
            }
            .quickLookPreview($editor.previewURL)
            .confirmationDialog(editor.attachmentTap?.ref.name ?? "", isPresented: Binding(get: { editor.attachmentTap != nil }, set: { if !$0 { editor.attachmentTap = nil } }), titleVisibility: .hidden) {
                if let t = editor.attachmentTap {
                    Button("Anzeigen") { editor.openAttachment(t.ref) }
                    if !editor.readonly {
                        Button("Anhang löschen", role: .destructive) { editor.deleteAttachment(t) }
                    }
                }
            }
            .alert("Notiz löschen?", isPresented: $confirmDelete) {
                Button("Löschen", role: .destructive) { store.delete([store.resolve(noteId)]); dismiss() }
                Button("Abbrechen", role: .cancel) {}
            } message: { Text("Die Notiz liegt danach 30 Tage in „Zuletzt gelöscht“.") }
            .alert("Anhang", isPresented: Binding(get: { attachError != nil }, set: { if !$0 { attachError = nil } })) {
                Button("OK") {}
            } message: { Text(attachError ?? "") }
    }

    private func setUp() {
        guard !loaded else { return }
        loaded = true
        editor.store = store
        editor.noteId = noteId
        editor.newNoteStyle = BlockKind(rawValue: newNoteStyle) ?? .title
        if let c = readonlyContent {
            editor.readonly = true
            editor.load(markdown: c, modified: nil, created: nil)
            return
        }
        guard let n = note else { return }
        editor.readonly = n.readonly
        editor.load(markdown: n.content, modified: n.isLocalOnly && n.content.isEmpty ? Date() : n.modifiedDate, created: n.createdDate)
        if n.content.isEmpty && !n.readonly {
            DispatchQueue.main.async { editor.textView.becomeFirstResponder() }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isTrash {
            ToolbarItem(placement: .bottomBar) {
                Button("Wiederherstellen") {
                    if let t = trashId { store.restore([t]) }
                    dismiss()
                }
            }
        } else {
            if editor.isEditing {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel(Text("Widerrufen"))
                    Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .accessibilityLabel(Text("Wiederholen"))
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let n = note {
                    ShareLink(item: NoteExport(title: n.displayTitle, content: n.content, asFile: false),
                              preview: SharePreview(n.displayTitle)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(Text("Teilen"))
                }
                moreMenu
            }
            if editor.isEditing {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editor.dismissKeyboard() } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.glassProminent)
                        .accessibilityLabel(Text("Fertig"))
                        .accessibilityIdentifier("done")
                }
            }
            if !editor.readonly {
                ToolbarItem(placement: .bottomBar) {
                    Button { editor.addChecklist() } label: { Image(systemName: "checklist") }
                        .accessibilityLabel(Text("Checkliste"))
                }
                ToolbarItem(placement: .bottomBar) {
                    AttachMenu { attach($0) } label: { Image(systemName: "paperclip") }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button { editor.insertTable() } label: { Image(systemName: "tablecells") }
                        .accessibilityLabel(Text("Tabelle"))
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    NewNoteButton(category: note?.category ?? "", replace: true)
                }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if let n = note {
                Button { editor.findInNote() } label: { Label("In Notiz suchen", systemImage: "magnifyingglass") }
                if !n.readonly {
                    Button { showMove = true } label: { Label("Bewegen", systemImage: "folder") }
                }
                Button { store.setFavorite([store.resolve(noteId)], !n.favorite) } label: {
                    Label(n.favorite ? "Loslösen" : "Anpinnen", systemImage: n.favorite ? "pin.slash" : "pin")
                }
                if editor.hasChecklist && !n.readonly {
                    Menu {
                        Button("Alle abhaken") { editor.checklist(.checkAll) }
                        Button("Alle Häkchen entfernen") { editor.checklist(.uncheckAll) }
                        Button("Markierte nach unten bewegen") { editor.checklist(.moveCheckedDown) }
                        Button("Markierte löschen", role: .destructive) { editor.checklist(.removeChecked) }
                    } label: { Label("Checkliste", systemImage: "checklist") }
                }
                Section {
                    ShareLink(item: NoteExport(title: n.displayTitle, content: n.content, asFile: true),
                              preview: SharePreview(n.displayTitle + ".md")) {
                        Label("Als Markdown exportieren", systemImage: "arrow.down.doc")
                    }
                    ShareLink(item: NoteExport(title: n.displayTitle, content: n.content, asFile: false),
                              preview: SharePreview(n.displayTitle)) {
                        Label("Kopie senden", systemImage: "square.and.arrow.up")
                    }
                }
                if !n.readonly {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Löschen", systemImage: "trash") }
                }
            }
        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel(Text("Mehr"))
        .accessibilityIdentifier("noteMore")
    }

    // MARK: Anhänge

    private func attach(_ s: AttachSource) {
        guard store.capabilities?.supportsAttachments ?? true else {
            attachError = String(localized: "Dein Server unterstützt keine Anhänge (Nextcloud Notes 4.12.3 oder neuer nötig).")
            return
        }
        switch s {
        case .photos: showPhotos = true
        case .camera: showCamera = true
        case .file: showFiles = true
        }
    }

    private func addAttachment(_ data: Data, _ name: String) {
        do {
            let path = try store.addAttachment(data: data, filename: name)
            editor.insertAttachment(path: path, name: (name as NSString).deletingPathExtension)
        } catch { attachError = error.localizedDescription }
    }

    private func importPhotos() async {
        let items = photoItems
        guard !items.isEmpty else { return }
        photoItems = []
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
            if isVideo {
                let ext = item.supportedContentTypes.first { $0.conforms(to: .movie) }?.preferredFilenameExtension ?? "mov"
                addAttachment(data, "Video-\(stamp).\(ext)")
            } else if let img = UIImage(data: data), let jpg = img.jpegData(compressionQuality: 0.85) {
                // HEIC → JPEG, damit das Bild auch im Nextcloud-Web erscheint
                addAttachment(jpg, "Foto-\(stamp).jpg")
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { addAttachment(data, url.lastPathComponent) }
        }
    }
}

/// Teilen: als Text (Kopie senden) oder als .md-Datei (Als Markdown exportieren).
struct NoteExport: Transferable {
    let title: String
    let content: String
    let asFile: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType("net.daringfireball.markdown") ?? .plainText) { e in
            let name = NoteStore.safeFilename(e.title.isEmpty ? "Notiz" : e.title) + ".md"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try e.content.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
        .exportingCondition { $0.asFile }
        ProxyRepresentation { e in e.content }
    }
}

/// „Neue Notiz“-Knopf (Stift auf Blatt), legt im angegebenen Ordner an.
struct NewNoteButton: View {
    let category: String
    var replace = false
    @Environment(NoteStore.self) private var store
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            let id = store.createNote(category: category)
            router.openNote(id, replace: replace)
        } label: { Image(systemName: "square.and.pencil") }
        .accessibilityLabel(Text("Neue Notiz"))
        .accessibilityIdentifier("compose")
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let done: (Data, String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let stamp = Int(Date().timeIntervalSince1970)
            if let url = info[.mediaURL] as? URL, let d = try? Data(contentsOf: url) {
                parent.done(d, "Video-\(stamp).\(url.pathExtension.isEmpty ? "mov" : url.pathExtension)")
            } else if let img = info[.originalImage] as? UIImage, let d = img.jpegData(compressionQuality: 0.85) {
                parent.done(d, "Foto-\(stamp).jpg")
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Link hinzufügen / bearbeiten.
struct LinkEditorSheet: View {
    @State var edit: LinkEdit
    let done: (LinkEdit, Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Link zu:", text: $edit.url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Name", text: $edit.text)
                }
                if !edit.url.isEmpty {
                    Section { Button("Link entfernen", role: .destructive) { done(edit, true); dismiss() } }
                }
            }
            .navigationTitle(edit.url.isEmpty ? "Link hinzufügen" : "Link bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { done(edit, false); dismiss() }.disabled(edit.url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

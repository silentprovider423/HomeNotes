import SwiftUI

enum Route: Hashable {
    case folder(FolderID)
    case note(Int)
    case trashNote(UUID)
}

@MainActor @Observable
final class Router {
    var path: [Route] = [.folder(.all)]

    func openNote(_ id: Int, replace: Bool = false) {
        if replace, case .note = path.last { path.removeLast() }
        path.append(.note(id))
    }
}

/// Angemeldet-Zustand (beobachtbar, damit Anmelden/Abmelden die Oberfläche umschaltet).
@MainActor @Observable
final class Session {
    static let shared = Session()
    var signedIn = NotesClient.shared.isSignedIn
}

struct RootView: View {
    @Environment(Session.self) private var session
    var body: some View {
        if session.signedIn { MainView() } else { LoginView() }
    }
}

struct MainView: View {
    @Environment(NoteStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var phase

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            FolderListView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .folder(let f): NoteListView(folder: f)
                    case .note(let id): NoteEditorView(noteId: id).id(id)
                    case .trashNote(let tid):
                        if let t = store.trash.first(where: { $0.id == tid }) {
                            NoteEditorView(noteId: 0, readonlyContent: t.content, trashId: t.id)
                        }
                    }
                }
        }
        .task {
            // regelmäßig abgleichen, solange die App offen ist (mit pruneBefore kostet das kaum etwas)
            while !Task.isCancelled {
                await store.sync()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: phase) {
            switch phase {
            case .active: Task { await store.sync() }
            case .background: store.saveNow(); Task { await store.push() }
            default: break
            }
        }
        .alert("Abgleich", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.clearError() } })) {
            Button("OK") { store.clearError() }
        } message: { Text(store.lastError ?? "") }
    }
}

/// Teilen-Blatt für Notizen aus der Liste.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable { let id = UUID(); let text: String }

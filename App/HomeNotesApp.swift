import SwiftUI

@main
struct HomeNotesApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

/// Vorläufige Ansicht zum Prüfen der Server-Anbindung – wird durch den Nachbau der Notizen-Oberfläche ersetzt.
struct ProbeView: View {
    @State private var notes: [Note] = []
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(notes) { n in
                    VStack(alignment: .leading) {
                        Text(n.title).font(.headline)
                        Text("\(n.category) · \(n.modifiedDate.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Notizen")
            .task {
                do { notes = try await NotesClient.shared.list() } catch { self.error = error.localizedDescription }
            }
        }
    }
}

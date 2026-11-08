import SwiftUI

@main
struct HomeNotesApp: App {
    @State private var store = NoteStore.shared
    @State private var router = Router()
    @State private var session = Session.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(router)
                .environment(session)
                .tint(Color.accentColor)
        }
    }
}

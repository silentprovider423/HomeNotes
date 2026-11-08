import SwiftUI
import AuthenticationServices

/// Anmelden per Browser (Nextcloud Login Flow v2): Server-Adresse eingeben, im Browser bei der eigenen Nextcloud
/// anmelden (auch mit Zwei-Faktor), die App bekommt ein eigenes App-Passwort.
struct LoginView: View {
    @Environment(NoteStore.self) private var store
    @Environment(Session.self) private var session
    @AppStorage("lastServer") private var address = ""
    @State private var busy = false
    @State private var error: String?
    @State private var flow = WebLogin()
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.accentColor.opacity(0.35), Color(.systemBackground), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                Image("LoginIcon").resizable().frame(width: 104, height: 104)
                    .clipShape(.rect(cornerRadius: 24))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                    .accessibilityHidden(true)
                VStack(spacing: 6) {
                    Text("HomeNotes").font(.largeTitle.bold())
                    Text("Deine Notizen in deiner eigenen Nextcloud").font(.title3).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer().frame(height: 10)
                GlassEffectContainer {
                    VStack(spacing: 14) {
                        HStack {
                            Image(systemName: "server.rack").foregroundStyle(.secondary)
                            TextField("Server-Adresse, z. B. cloud.example.com", text: $address)
                                .keyboardType(.URL).textContentType(.URL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .submitLabel(.go).onSubmit(start)
                                .focused($focused)
                                .accessibilityIdentifier("serverAddress")
                        }
                        .padding(.horizontal, 18).frame(height: 54)
                        .glassEffect(.regular.interactive(), in: .capsule)

                        Button(action: start) {
                            HStack {
                                if busy { ProgressView().tint(.black) }
                                Text(busy ? "Warte auf Anmeldung im Browser …" : "Im Browser anmelden").font(.headline)
                            }
                            .frame(maxWidth: .infinity).frame(height: 44)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                        .accessibilityIdentifier("signIn")
                    }
                }
                .padding(.horizontal, 24)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal, 30)
                }
                Spacer()
                Text("Die App bekommt ein eigenes App-Passwort – dein Nextcloud-Passwort sieht sie nie. Nötig ist die Nextcloud-App „Notes“.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 32).padding(.bottom, 12)
            }
        }
        .onTapGesture { focused = false }
    }

    private func start() {
        guard !busy else { return }
        error = nil
        busy = true
        focused = false
        Task {
            defer { busy = false }
            do {
                let s = try await LoginFlow.start(address)
                let result = try await flow.run(login: s.login, poll: s.poll)
                NotesClient.shared.signIn(server: result.server, user: result.loginName, appPassword: result.appPassword)
                // Notes-App vorhanden?
                let caps = try await NotesClient.shared.capabilities()
                guard caps.isUsable else {
                    await NotesClient.shared.signOut()
                    throw NotesError.notNotesServer
                }
                store.reloadForAccount()
                session.signedIn = true
                Task { await store.sync() }
            } catch is CancellationError {
            } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Öffnet die Anmeldeseite in einem Browser-Blatt und fragt parallel ab, bis Nextcloud das App-Passwort herausgibt.
@MainActor
final class WebLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func run(login: URL, poll: LoginFlow.Start.Poll) async throws -> LoginFlow.Result {
        try await withThrowingTaskGroup(of: LoginFlow.Result?.self) { group in
            let (stream, cont) = AsyncStream<Error?>.makeStream()
            let s = ASWebAuthenticationSession(url: login, callback: .customScheme("homenotes")) { _, err in
                cont.yield(err ?? CancellationError()); cont.finish()
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = true
            session = s
            s.start()
            group.addTask { try await LoginFlow.poll(poll) }
            group.addTask {
                // Browser zu, bevor die Anmeldung fertig war → abbrechen
                for await e in stream { if let e { throw e } }
                return nil
            }
            defer { s.cancel(); cont.finish(); group.cancelAll() }
            while let r = try await group.next() {
                if let r { return r }
            }
            throw CancellationError()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}

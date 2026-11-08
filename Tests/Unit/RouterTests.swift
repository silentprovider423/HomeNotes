import XCTest
@testable import HomeNotes

/// Neue Notiz landet wie bei Apple im angesehenen Ordner – aus „Alle Notizen“ (auch aus einer dort geöffneten
/// Notiz eines anderen Ordners) im Standardordner „Notizen“.
final class RouterTests: XCTestCase {
    func testNewNoteFolder() {
        // Alle Notizen → Notiz aus „Travel“ geöffnet → Standardordner
        XCTAssertEqual(Router.category(forNewNoteIn: [.folder(.all), .note(12)]), "")
        XCTAssertEqual(Router.category(forNewNoteIn: [.folder(.all)]), "")
        // Ordner „Travel“ angesehen (auch mit offener Notiz) → Travel
        XCTAssertEqual(Router.category(forNewNoteIn: [.folder(.category("Travel"))]), "Travel")
        XCTAssertEqual(Router.category(forNewNoteIn: [.folder(.all), .folder(.category("Work/Projects")), .note(3)]), "Work/Projects")
        // Ordner „Notizen“, Zuletzt gelöscht, Suche aus der Ordnerliste
        XCTAssertEqual(Router.category(forNewNoteIn: [.folder(.category("")), .note(1)]), "")
        XCTAssertEqual(Router.category(forNewNoteIn: [.folder(.trash)]), "")
        XCTAssertEqual(Router.category(forNewNoteIn: [.note(5)]), "")
    }
}

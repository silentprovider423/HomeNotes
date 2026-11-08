import XCTest

/// Selbsttest der Oberfläche gegen das Testkonto (Zugang per TEST_RUNNER_NOTES_*):
/// neue Notiz schreiben, Checkliste, zurück, Suche, anpinnen, löschen, „Zuletzt gelöscht“ leeren.
final class HomeNotesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testNoteLifecycle() throws {
        let env = ProcessInfo.processInfo.environment
        guard let s = env["NOTES_SERVER"], let u = env["NOTES_USER"], let p = env["NOTES_PASSWORD"], !s.isEmpty else {
            throw XCTSkip("Kein Testkonto")
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["NOTES_SERVER": s, "NOTES_USER": u, "NOTES_PASSWORD": p]
        app.launchArguments = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]   // Knopf-Texte unten sind deutsch
        app.launch()

        let stamp = String(Int(Date().timeIntervalSince1970) % 100000)
        let title = "UI Test \(stamp)"

        // neue Notiz
        let compose = app.buttons["compose"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 20))
        compose.tap()
        let editor = app.textViews["editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.typeText("\(title)\nErste Zeile\n")
        // Checkliste über die Leiste über der Tastatur
        app.buttons["Checkliste"].firstMatch.tap()
        editor.typeText("Punkt A\nPunkt B")
        XCTAssertTrue(editor.value.debugDescription.contains("Punkt B"))
        app.buttons["done"].firstMatch.tap()

        // zurück zur Liste, Zeile da
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.buttons["note.\(title)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        // anpinnen per Wischen nach rechts
        row.swipeRight()
        app.buttons["Anpinnen"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Angepinnt"].waitForExistence(timeout: 5))

        // Suche findet die Notiz über den Inhalt, dort per Wischen nach links löschen
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Punkt")
        let found = app.buttons["note.\(title)"].firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: 5))
        found.swipeLeft()
        app.buttons["Löschen"].firstMatch.tap()
        XCTAssertFalse(app.buttons["note.\(title)"].firstMatch.waitForExistence(timeout: 3))
        // neu starten (Suche zu, Zwischenspeicher muss den Stand halten)
        app.terminate()
        app.launch()
        XCTAssertFalse(app.buttons["note.\(title)"].firstMatch.waitForExistence(timeout: 3))

        // in „Zuletzt gelöscht“ endgültig löschen
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let trash = app.buttons["folder.trash"].firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 10))
        trash.tap()
        let trashed = app.staticTexts[title].firstMatch
        XCTAssertTrue(trashed.waitForExistence(timeout: 5))
        trashed.swipeLeft()
        app.buttons["Löschen"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts[title].firstMatch.waitForExistence(timeout: 3))
    }
}

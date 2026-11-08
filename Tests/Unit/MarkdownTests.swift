import XCTest
@testable import HomeNotes

/// Markdown ⇄ Absätze ⇄ Editor-Text: Was aus Nextcloud kommt, muss nach dem Speichern genauso dort stehen.
final class MarkdownTests: XCTestCase {

    /// Dateien, die beim Öffnen und Speichern unverändert bleiben müssen.
    static let stable = [
        "# Einkaufsliste\n\n- [ ] Milch\n- [x] Brot\n  - [ ] Butter\n\nNormaler **fetter** und *kursiver* Text mit ~~weg~~ und <u>unter</u>.",
        "## Überschrift\n### Unter\n#### Tiefer\n* Punkt\n- Strich\n1. eins\n2. zwei\n  1. drei\n> Zitat mit [Link](https://example.com)",
        "```swift\nlet x = 1 * 2\n```\nEnde https://nextcloud.com/x. hier",
        "| A | B |\n| --- | :---: |\n| 1 | **2** |\n| x\\|y | z |\n\n![bild](.attachments.12/Foto%201.jpg)\n[doc.pdf](.attachments.12/doc.pdf)",
        "\\# Kein Titel\n1\\. keine Liste\n\\- kein Strich\n***\n---\n**fett *beides* fett** ende",
        "a `code` b ``x`y`` c",
        "Sterne *** und 2 * 3 * 4 und snake_case_name",
        "",
        "Zeile\n",
        "#tag am Anfang und #noch-einer",
        "- [ ] \n- [x] erledigt",
    ]

    func testRoundTripStable() {
        for s in Self.stable {
            XCTAssertEqual(MarkdownCodec.serialize(MarkdownCodec.parse(s)), s, "nicht stabil: \(s.debugDescription)")
        }
    }

    func testParseKinds() {
        let p = MarkdownCodec.parse("# T\n## H\n### S\n- [x] a\n  * b\n3. c\n> q\ntext")
        XCTAssertEqual(p.map(\.kind), [.title, .heading, .subheading, .check, .bullet, .number, .quote, .body])
        XCTAssertTrue(p[3].checked)
        XCTAssertEqual(p[4].indent, 1)
    }

    func testInlineSerialize() {
        let m = NSMutableAttributedString(string: "x ")
        m.append(NSAttributedString(string: "fett", attributes: [.hnBold: true]))
        m.append(NSAttributedString(string: " und "))
        m.append(NSAttributedString(string: "beides", attributes: [.hnBold: true, .hnItalic: true]))
        m.append(NSAttributedString(string: " *stern*"))
        let s = Inline.serialize(m)
        XCTAssertEqual(s, "x **fett** und **_beides_** \\*stern\\*")
        XCTAssertTrue(Inline.equal(Inline.parse(s), m))
    }

    func testBodyEscaping() {
        let p = Paragraph(kind: .body, text: NSAttributedString(string: "# kein Titel"))
        let md = MarkdownCodec.serialize([p])
        XCTAssertEqual(md, "\\# kein Titel")
        XCTAssertEqual(MarkdownCodec.parse(md).first?.kind, .body)
    }

    func testNumberingIsSequential() {
        let p = MarkdownCodec.parse("1. a\n1. b\n1. c")
        XCTAssertEqual(MarkdownCodec.serialize(p), "1. a\n2. b\n3. c")
    }

    func testTitleAndPreview() {
        var n = LocalNote(id: 1, title: "x", content: "# Einkauf\n\n- [ ] **Milch**\n- Brot", category: "", favorite: false, modified: 0)
        XCTAssertEqual(n.displayTitle, "Einkauf")
        XCTAssertEqual(n.preview, "Milch")
        n.content = "![](.attachments.1/a.jpg)\nText"
        XCTAssertEqual(n.firstImagePath, ".attachments.1/a.jpg")
    }

    func testTable() {
        let p = MarkdownCodec.parse("| a | b |\n|---|---|\n| 1 | 2 |")
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].table?.rows, [["a", "b"], ["1", "2"]])
    }

    /// Editor-Weg: Markdown → formatierter Text mit Kreisen/Zeichen → Markdown.
    @MainActor
    func testEditorRoundTrip() {
        for s in Self.stable {
            let a = Styler.attributed(MarkdownCodec.parse(s), width: 350)
            let back = MarkdownCodec.serialize(Styler.paragraphs(from: a))
            XCTAssertEqual(back, s, "Editor verändert: \(s.debugDescription)")
        }
    }

    @MainActor
    func testEditorMarkersAreNotContent() {
        let a = Styler.attributed(MarkdownCodec.parse("- [ ] eins\n* zwei\n1. drei"), width: 350)
        XCTAssertTrue(a.string.contains("•\t"))
        XCTAssertTrue(a.string.contains("1.\t"))
        let paras = Styler.paragraphs(from: a)
        XCTAssertEqual(paras.map { $0.text.string }, ["eins", "zwei", "drei"])
    }
}

final class MergeTests: XCTestCase {
    func testMergesDifferentLines() {
        let base = "a\nb\nc\nd"
        let mine = "A\nb\nc\nd"
        let theirs = "a\nb\nc\nD\ne"
        XCTAssertEqual(Merge3.merge(base: base, mine: mine, theirs: theirs), "A\nb\nc\nD\ne")
    }

    func testConflictSameLine() {
        XCTAssertNil(Merge3.merge(base: "a\nb", mine: "a\nX", theirs: "a\nY"))
    }

    func testSameChangeBothSides() {
        XCTAssertEqual(Merge3.merge(base: "a", mine: "a\nb", theirs: "a\nb"), "a\nb")
    }

    func testChecklistToggleAndAppend() {
        let base = "# Liste\n- [ ] Milch\n- [ ] Brot"
        let mine = "# Liste\n- [x] Milch\n- [ ] Brot"
        let theirs = "# Liste\n- [ ] Milch\n- [ ] Brot\n- [ ] Eier"
        XCTAssertEqual(Merge3.merge(base: base, mine: mine, theirs: theirs), "# Liste\n- [x] Milch\n- [ ] Brot\n- [ ] Eier")
    }
}

final class SearchIndexTests: XCTestCase {
    func testPrefixAndDiacritics() {
        var i = SearchIndex()
        i.update(id: 1, title: "Einkaufsliste", text: "Äpfel und Brötchen")
        i.update(id: 2, title: "Reise", text: "Brot für unterwegs")
        XCTAssertEqual(Set(i.search("brot").keys), [1, 2])
        XCTAssertEqual(Set(i.search("apfel").keys), [1])
        XCTAssertEqual(i.search("einkauf")[1], 2)       // Treffer im Titel
        XCTAssertTrue(i.search("brot reise").keys.elementsEqual([2]))
    }
}

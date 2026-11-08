import Foundation

/// Absatzarten wie in Apples Notizen (Format-Menü „Aa“) plus Tabelle.
nonisolated enum BlockKind: String, Codable, Sendable, CaseIterable {
    case title, heading, subheading, body, mono, bullet, dash, number, check, quote, table

    var isList: Bool { self == .bullet || self == .dash || self == .number || self == .check }
    var hasMarker: Bool { isList || self == .quote }
}

nonisolated extension NSAttributedString.Key {
    // Bedeutung (wird nach Markdown geschrieben)
    static let hnBlock = NSAttributedString.Key("hn.block")          // String (BlockKind.rawValue)
    static let hnIndent = NSAttributedString.Key("hn.indent")        // Int
    static let hnChecked = NSAttributedString.Key("hn.checked")      // Bool
    static let hnLevel = NSAttributedString.Key("hn.level")          // Int (Überschrift ### … ######)
    static let hnFence = NSAttributedString.Key("hn.fence")          // String (Sprache des Codeblocks)
    static let hnBold = NSAttributedString.Key("hn.bold")
    static let hnItalic = NSAttributedString.Key("hn.italic")
    static let hnStrike = NSAttributedString.Key("hn.strike")
    static let hnUnderline = NSAttributedString.Key("hn.underline")
    static let hnCode = NSAttributedString.Key("hn.code")
    static let hnLink = NSAttributedString.Key("hn.link")            // String (Ziel)
    static let hnAutolink = NSAttributedString.Key("hn.autolink")    // Bool (nackte URL im Text)
    static let hnAttachment = NSAttributedString.Key("hn.attachment") // AttachmentRef
    static let hnTable = NSAttributedString.Key("hn.table")          // TableBox
    // nur Darstellung
    static let hnMarker = NSAttributedString.Key("hn.marker")        // Bool: Aufzählungszeichen/Kreis, kein Inhalt
}

/// Verweis auf einen Anhang (`![name](pfad)` bzw. `[name](pfad)`).
nonisolated final class AttachmentRef: NSObject, @unchecked Sendable {
    let path: String
    let name: String
    let isImage: Bool
    init(path: String, name: String, isImage: Bool) { self.path = path; self.name = name; self.isImage = isImage }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? AttachmentRef else { return false }
        return o.path == path && o.name == name && o.isImage == isImage
    }
    override var hash: Int { path.hashValue }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff"]
    static func looksLikeImage(_ path: String) -> Bool {
        imageExtensions.contains((path.split(separator: "?").first.map(String.init) ?? path).split(separator: ".").last.map { $0.lowercased() } ?? "")
    }
    /// Pfad ohne %-Kodierung (so erwartet ihn die Anhang-API).
    var decodedPath: String { path.removingPercentEncoding ?? path }
}

/// Tabelle (GFM). Zellen enthalten Inline-Markdown als Text.
nonisolated final class TableBox: NSObject, @unchecked Sendable {
    var rows: [[String]]
    var alignments: [String]   // je Spalte: "", "left", "center", "right"
    init(rows: [[String]], alignments: [String] = []) {
        self.rows = rows
        self.alignments = alignments
        super.init()
        normalize()
    }
    var columns: Int { rows.map(\.count).max() ?? 0 }

    func normalize() {
        let c = max(columns, 1)
        if rows.isEmpty { rows = [Array(repeating: "", count: c)] }
        rows = rows.map { $0 + Array(repeating: "", count: c - $0.count) }
        if alignments.count < c { alignments += Array(repeating: "", count: c - alignments.count) }
        if alignments.count > c { alignments = Array(alignments.prefix(c)) }
    }

    func copy() -> TableBox { TableBox(rows: rows, alignments: alignments) }

    override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? TableBox else { return false }
        return o.rows == rows && o.alignments == alignments
    }
    override var hash: Int { rows.count }
}

/// Ein Absatz einer Notiz (eine Zeile im Markdown, Tabellen und Codeblöcke über mehrere Zeilen).
nonisolated struct Paragraph: Equatable {
    var kind: BlockKind = .body
    var indent = 0
    var checked = false
    var level = 0                 // nur Unterüberschrift: 3…6
    var fence: String?            // nur mono: Sprache aus ```swift
    var text = NSAttributedString()   // Inhalt mit Bedeutungs-Attributen (ohne Aufzählungszeichen)
    var table: TableBox?

    static func == (a: Paragraph, b: Paragraph) -> Bool {
        a.kind == b.kind && a.indent == b.indent && a.checked == b.checked && a.level == b.level
            && a.fence == b.fence && Inline.equal(a.text, b.text) && a.table == b.table
    }
}

/// Markdown ⇄ Absätze. Bewusst zeilentreu: jede Zeile der Datei ist ein Absatz, Leerzeilen bleiben erhalten –
/// so sieht die Datei in Nextcloud aus wie die Notiz, und unverstandenes Markdown bleibt beim Speichern stehen.
nonisolated enum MarkdownCodec {

    // MARK: Lesen

    static func parse(_ markdown: String) -> [Paragraph] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [Paragraph] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            // Codeblock ```
            if let info = fenceStart(line) {
                var j = i + 1
                var body: [String] = []
                while j < lines.count, fenceStart(lines[j]) != "" {      // schließende ``` ohne Sprache
                    body.append(lines[j]); j += 1
                }
                if body.isEmpty { body = [""] }
                for (k, b) in body.enumerated() {
                    out.append(Paragraph(kind: .mono, fence: k == 0 ? info : nil, text: NSAttributedString(string: b)))
                }
                i = min(j + 1, lines.count)
                continue
            }
            // Tabelle: Kopfzeile + Trennzeile
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|"), i + 1 < lines.count, let al = separatorRow(lines[i + 1]) {
                var rows = [splitRow(line)]
                var j = i + 2
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(splitRow(lines[j])); j += 1
                }
                let t = TableBox(rows: rows, alignments: al)
                out.append(Paragraph(kind: .table, text: NSAttributedString(string: "\u{FFFC}"), table: t))
                i = j
                continue
            }
            out.append(parseLine(line))
            i += 1
        }
        return out
    }

    /// Eine Zeile → Absatz (ohne Codeblock/Tabelle).
    static func parseLine(_ line: String) -> Paragraph {
        if let m = line.firstMatch(of: /^(#{1,6})(?:[ \t]+(.*))?$/) {
            let lv = m.1.count
            var p = Paragraph(kind: lv == 1 ? .title : lv == 2 ? .heading : .subheading)
            p.level = lv >= 3 ? lv : 0
            p.text = Inline.parse(String(m.2 ?? ""))
            return p
        }
        if let m = line.firstMatch(of: /^([ \t]*)([-*+]|\d{1,9}[.)])[ \t]+(?:\[([ xX])\](?:[ \t]+|$))?(.*)$/) {
            var p = Paragraph()
            let ws = m.1.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            p.indent = min(ws / 2, 8)
            let mk = String(m.2)
            if let c = m.3 {
                p.kind = .check; p.checked = c != " "
            } else if mk == "-" { p.kind = .dash }
            else if mk == "*" || mk == "+" { p.kind = .bullet }
            else { p.kind = .number }
            p.text = Inline.parse(String(m.4))
            return p
        }
        if let m = line.firstMatch(of: /^>[ ]?(.*)$/) {
            return Paragraph(kind: .quote, text: Inline.parse(String(m.1)))
        }
        return Paragraph(kind: .body, text: Inline.parse(line))
    }

    static func fenceStart(_ line: String) -> String? {
        guard let m = line.firstMatch(of: /^ {0,3}```[ \t]*([^`]*)$/) else { return nil }
        return String(m.1).trimmingCharacters(in: .whitespaces)
    }

    static func separatorRow(_ line: String) -> [String]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.firstMatch(of: /^\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?$/) != nil else { return nil }
        return splitRow(t).map { c in
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            return l && r ? "center" : l ? "left" : r ? "right" : ""
        }
    }

    static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var cur = ""
        var esc = false
        for ch in t {
            if esc { cur.append(ch); esc = false; continue }
            if ch == "\\" { cur.append(ch); esc = true; continue }
            if ch == "|" { cells.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Schreiben

    static func serialize(_ paragraphs: [Paragraph]) -> String {
        var lines: [String] = []
        var number: [Int: Int] = [:]      // laufende Nummer je Einrückung
        var i = 0
        while i < paragraphs.count {
            let p = paragraphs[i]
            if p.kind != .number { number = number.filter { $0.key < p.indent } }
            switch p.kind {
            case .mono:
                lines.append("```" + (p.fence ?? ""))
                var j = i
                while j < paragraphs.count, paragraphs[j].kind == .mono {
                    if j > i, paragraphs[j].fence != nil { break }       // neuer Codeblock
                    lines.append(paragraphs[j].text.string); j += 1
                }
                lines.append("```")
                i = j
                continue
            case .table:
                if let t = p.table { lines += tableLines(t) }
            case .title, .heading, .subheading:
                let hashes = p.kind == .title ? "#" : p.kind == .heading ? "##" : String(repeating: "#", count: max(3, p.level))
                let s = Inline.serialize(p.text)
                lines.append(s.isEmpty ? hashes : hashes + " " + s)
            case .quote:
                lines.append("> " + Inline.serialize(p.text))
            case .bullet, .dash, .check, .number:
                let pad = String(repeating: "  ", count: p.indent)
                // tiefere Ebenen beenden die Zählung nicht, flachere schon
                number = number.filter { $0.key <= p.indent }
                let mk: String
                switch p.kind {
                case .bullet: mk = "* "
                case .dash: mk = "- "
                case .check: mk = p.checked ? "- [x] " : "- [ ] "
                default:
                    let n = (number[p.indent] ?? 0) + 1
                    number[p.indent] = n
                    mk = "\(n). "
                }
                if p.kind != .number { number[p.indent] = nil }
                lines.append(pad + mk + Inline.serialize(p.text))
            case .body:
                lines.append(bodyLine(p.text))
            }
            i += 1
        }
        return lines.joined(separator: "\n")
    }

    /// Fließtext so schreiben, dass er beim Lesen wieder Fließtext ist (z. B. „# “ am Anfang maskieren).
    static func bodyLine(_ text: NSAttributedString) -> String {
        let s = Inline.serialize(text)
        let back = parseLine(s)
        if back.kind == .body, fenceStart(s) == nil { return s }
        // erstes Zeichen nach Leerraum maskieren
        guard let idx = s.firstIndex(where: { $0 != " " && $0 != "\t" }) else { return s }
        if s[idx].isNumber, let dot = s[idx...].firstIndex(where: { $0 == "." || $0 == ")" }) {
            var t = s; t.insert("\\", at: dot); return t
        }
        var t = s; t.insert("\\", at: idx); return t
    }

    static func tableLines(_ t: TableBox) -> [String] {
        t.normalize()
        func row(_ r: [String]) -> String {
            "| " + r.map { $0.replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\\\\|", with: "\\|") }
                .joined(separator: " | ") + " |"
        }
        var out = [row(t.rows[0])]
        out.append("| " + t.alignments.map { a in
            switch a { case "left": ":---"; case "center": ":---:"; case "right": "---:"; default: "---" }
        }.joined(separator: " | ") + " |")
        for r in t.rows.dropFirst() { out.append(row(r)) }
        return out
    }

    // MARK: Hilfen für Liste und Titel

    /// Klartext ohne Markdown-Zeichen (Titel, Vorschau, Suche).
    static func plainText(_ markdown: String) -> String {
        parse(markdown).map { p -> String in
            if let t = p.table { return t.rows.map { $0.map { Inline.parse($0).string }.joined(separator: " ") }.joined(separator: "\n") }
            return p.text.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        }.joined(separator: "\n")
    }

    /// Titel einer Notiz = erste nicht leere Zeile (wie Apple), höchstens 100 Zeichen.
    static func title(of markdown: String) -> String {
        for line in plainText(markdown).split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(100)) }
        }
        return ""
    }

    /// Anhang-Verweise (Pfade) im Text.
    static func attachmentPaths(_ markdown: String) -> [String] {
        var out: [String] = []
        for p in parse(markdown) {
            p.text.enumerateAttribute(.hnAttachment, in: NSRange(location: 0, length: p.text.length)) { v, _, _ in
                if let r = v as? AttachmentRef { out.append(r.path) }
            }
        }
        return out
    }
}

/// Inline-Markdown: **fett**, *kursiv*, ~~durchgestrichen~~, <u>unterstrichen</u>, `Code`, [Link](url), ![Bild](pfad).
nonisolated enum Inline {
    static let semanticKeys: [NSAttributedString.Key] = [.hnBold, .hnItalic, .hnStrike, .hnUnderline, .hnCode, .hnLink, .hnAutolink, .hnAttachment]

    // MARK: Lesen

    static func parse(_ s: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        parse(Array(s), into: out, base: [:])
        return out
    }

    private static func isPunct(_ c: Character) -> Bool {
        c.isASCII && (c.isPunctuation || c.isSymbol)
    }

    private static func parse(_ s: [Character], into out: NSMutableAttributedString, base: [NSAttributedString.Key: Any]) {
        var attrs = base
        var buf = ""
        func flush() {
            if !buf.isEmpty { out.append(NSAttributedString(string: buf, attributes: attrs)); buf = "" }
        }
        func starts(_ t: String, at i: Int) -> Bool {
            let a = Array(t)
            guard i + a.count <= s.count else { return false }
            return Array(s[i..<(i + a.count)]) == a
        }
        func find(_ t: String, from: Int, requireNonSpaceBefore: Bool) -> Int? {
            let a = Array(t)
            var j = from
            while j + a.count <= s.count {
                if s[j] == "\\" { j += 2; continue }
                if Array(s[j..<(j + a.count)]) == a, !requireNonSpaceBefore || (j > from && !s[j - 1].isWhitespace) { return j }
                j += 1
            }
            return nil
        }
        func toggle(_ key: NSAttributedString.Key, _ delim: String, at i: inout Int, wordRule: Bool = false) -> Bool {
            let n = delim.count
            if attrs[key] != nil {
                // schließen: davor kein Leerzeichen
                guard i > 0, !s[i - 1].isWhitespace else { return false }
                if wordRule, i + n < s.count, s[i + n].isLetter || s[i + n].isNumber { return false }
                flush(); attrs[key] = nil; i += n; return true
            }
            // öffnen: danach kein Leerzeichen und nicht dasselbe Zeichen („***“ bleibt Text), Gegenstück vorhanden
            guard i + n < s.count, !s[i + n].isWhitespace, s[i + n] != s[i] else { return false }
            if wordRule, i > 0, s[i - 1].isLetter || s[i - 1].isNumber { return false }
            guard let j = find(delim, from: i + n, requireNonSpaceBefore: true), j > i + n else { return false }
            flush(); attrs[key] = true; i += n; return true
        }

        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\\", i + 1 < s.count, isPunct(s[i + 1]) { buf.append(s[i + 1]); i += 2; continue }
            if c == "`", attrs[.hnCode] == nil, let j = find("`", from: i + 1, requireNonSpaceBefore: false), j > i + 1 {
                flush()
                var a = attrs; a[.hnCode] = true
                out.append(NSAttributedString(string: String(s[(i + 1)..<j]), attributes: a))
                i = j + 1; continue
            }
            if starts("**", at: i), toggle(.hnBold, "**", at: &i) { continue }
            if starts("__", at: i), toggle(.hnBold, "__", at: &i, wordRule: true) { continue }
            if starts("~~", at: i), toggle(.hnStrike, "~~", at: &i) { continue }
            if c == "*", toggle(.hnItalic, "*", at: &i) { continue }
            if c == "_", toggle(.hnItalic, "_", at: &i, wordRule: true) { continue }
            if starts("<u>", at: i), attrs[.hnUnderline] == nil, find("</u>", from: i + 3, requireNonSpaceBefore: false) != nil {
                flush(); attrs[.hnUnderline] = true; i += 3; continue
            }
            if starts("</u>", at: i), attrs[.hnUnderline] != nil { flush(); attrs[.hnUnderline] = nil; i += 4; continue }
            if c == "[" || (c == "!" && i + 1 < s.count && s[i + 1] == "["), let (text, dest, end) = link(s, at: c == "!" ? i + 1 : i) {
                flush()
                if c == "!" || isAttachmentPath(dest) {
                    var a = attrs
                    a[.hnAttachment] = AttachmentRef(path: dest, name: text, isImage: c == "!" || AttachmentRef.looksLikeImage(dest))
                    out.append(NSAttributedString(string: "\u{FFFC}", attributes: a))
                } else {
                    var a = attrs; a[.hnLink] = dest
                    parse(Array(text), into: out, base: a)
                }
                i = end; continue
            }
            if c == "h", (i == 0 || !(s[i - 1].isLetter || s[i - 1].isNumber)), starts("https://", at: i) || starts("http://", at: i) {
                var j = i
                while j < s.count, !s[j].isWhitespace, s[j] != "<", s[j] != ">" { j += 1 }
                while j > i, ".,;:!?)\"'".contains(s[j - 1]) { j -= 1 }
                let url = String(s[i..<j])
                if url.count > 8 {
                    flush()
                    var a = attrs; a[.hnLink] = url; a[.hnAutolink] = true
                    out.append(NSAttributedString(string: url, attributes: a))
                    i = j; continue
                }
            }
            buf.append(c); i += 1
        }
        flush()
    }

    /// `[text](ziel)` ab Position der öffnenden Klammer → (Text, Ziel, Ende).
    private static func link(_ s: [Character], at i: Int) -> (String, String, Int)? {
        guard i < s.count, s[i] == "[" else { return nil }
        var depth = 0, j = i
        while j < s.count {
            if s[j] == "\\" { j += 2; continue }
            if s[j] == "[" { depth += 1 }
            if s[j] == "]" { depth -= 1; if depth == 0 { break } }
            j += 1
        }
        guard j + 1 < s.count, s[j] == "]", s[j + 1] == "(" else { return nil }
        var k = j + 2
        var dest = ""
        if k < s.count, s[k] == "<" {
            k += 1
            while k < s.count, s[k] != ">" { dest.append(s[k]); k += 1 }
            k += 1
        } else {
            var par = 0
            while k < s.count {
                if s[k] == "(" { par += 1 }
                if s[k] == ")" { if par == 0 { break }; par -= 1 }
                if s[k] == " " { break }
                dest.append(s[k]); k += 1
            }
        }
        // optionaler Titel "…" wird übersprungen
        while k < s.count, s[k] != ")" { k += 1 }
        guard k < s.count, s[k] == ")" else { return nil }
        return (String(s[(i + 1)..<j]), dest, k + 1)
    }

    static func isAttachmentPath(_ dest: String) -> Bool {
        dest.hasPrefix(".attachments.") || dest.hasPrefix(PendingAttachment.scheme)
    }

    // MARK: Schreiben

    private struct Flags: Equatable {
        var bold = false, italic = false, strike = false, underline = false
        static let none = Flags()
        func intersect(_ o: Flags) -> Flags {
            Flags(bold: bold && o.bold, italic: italic && o.italic, strike: strike && o.strike, underline: underline && o.underline)
        }
    }

    private enum Piece {
        case text(String, Flags)
        case code(String, Flags)
        case link(NSAttributedString, String, Flags)     // innerer Text, Ziel
        case raw(String, Flags)                          // Anhang, nackte URL
        var flags: Flags {
            get { switch self { case .text(_, let f), .code(_, let f), .link(_, _, let f), .raw(_, let f): f } }
            set {
                switch self {
                case .text(let s, _): self = .text(s, newValue)
                case .code(let s, _): self = .code(s, newValue)
                case .link(let a, let d, _): self = .link(a, d, newValue)
                case .raw(let s, _): self = .raw(s, newValue)
                }
            }
        }
        var isBlank: Bool { if case .text(let s, _) = self { return s.allSatisfy(\.isWhitespace) }; return false }
        var isNeutral: Bool { if case .raw = self { return true }; return isBlank }
    }

    static func serialize(_ text: NSAttributedString) -> String {
        let plain = emit(text, escapeAll: false)
        if equal(parse(plain), text) { return plain }
        let escaped = emit(text, escapeAll: true)
        if equal(parse(escaped), text) { return escaped }
        return plain.count <= escaped.count ? escaped : plain
    }

    private static func flags(_ a: [NSAttributedString.Key: Any]) -> Flags {
        Flags(bold: a[.hnBold] != nil, italic: a[.hnItalic] != nil, strike: a[.hnStrike] != nil, underline: a[.hnUnderline] != nil)
    }

    private static func emit(_ text: NSAttributedString, escapeAll: Bool) -> String {
        var pieces: [Piece] = []
        let full = NSRange(location: 0, length: text.length)
        let ns = text.string as NSString
        var i = 0
        while i < full.length {
            var r = NSRange()
            let a = text.attributes(at: i, longestEffectiveRange: &r, in: full)
            if let ref = a[.hnAttachment] as? AttachmentRef {
                let p = ref.path.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                let name = ref.name.replacingOccurrences(of: "]", with: "")
                pieces.append(.raw((ref.isImage ? "!" : "") + "[\(name)](\(p))", flags(a)))
                i += 1; continue
            }
            if let dest = a[.hnLink] as? String {
                // ganzen Link (auch mit wechselnder Formatierung) zusammenfassen
                var end = i
                while end < full.length, (text.attribute(.hnLink, at: end, effectiveRange: nil) as? String) == dest,
                      text.attribute(.hnAttachment, at: end, effectiveRange: nil) == nil { end += 1 }
                let sub = text.attributedSubstring(from: NSRange(location: i, length: end - i))
                var common = Flags(bold: true, italic: true, strike: true, underline: true)
                sub.enumerateAttributes(in: NSRange(location: 0, length: sub.length)) { at, _, _ in common = common.intersect(flags(at)) }
                if a[.hnAutolink] != nil, sub.string == dest {
                    pieces.append(.raw(dest, common))
                } else {
                    let inner = NSMutableAttributedString(attributedString: sub)
                    let ir = NSRange(location: 0, length: inner.length)
                    inner.removeAttribute(.hnLink, range: ir); inner.removeAttribute(.hnAutolink, range: ir)
                    if common.bold { inner.removeAttribute(.hnBold, range: ir) }
                    if common.italic { inner.removeAttribute(.hnItalic, range: ir) }
                    if common.strike { inner.removeAttribute(.hnStrike, range: ir) }
                    if common.underline { inner.removeAttribute(.hnUnderline, range: ir) }
                    pieces.append(.link(inner, dest, common))
                }
                i = end; continue
            }
            var len = r.location + r.length - i
            // Anhänge innerhalb des Laufs abtrennen
            let s = ns.substring(with: NSRange(location: i, length: len))
            if let k = s.firstIndex(of: "\u{FFFC}"), text.attribute(.hnAttachment, at: i + s.utf16.distance(from: s.startIndex, to: k), effectiveRange: nil) != nil {
                len = s.utf16.distance(from: s.startIndex, to: k)
            }
            let str = ns.substring(with: NSRange(location: i, length: max(len, 1)))
            if a[.hnCode] != nil { pieces.append(.code(str, flags(a))) }
            else {
                // Leerraum an den Rändern abtrennen, damit „**a **“ nicht entsteht
                let f = flags(a)
                let lead = str.prefix { $0 == " " || $0 == "\t" }
                let rest = str.dropFirst(lead.count)
                let trail = rest.reversed().prefix { $0 == " " || $0 == "\t" }
                let core = rest.dropLast(trail.count)
                if !lead.isEmpty { pieces.append(.text(String(lead), f)) }
                if !core.isEmpty { pieces.append(.text(String(core), f)) }
                if !trail.isEmpty { pieces.append(.text(String(trail), f)) }
            }
            i += max(len, 1)
        }
        // neutrale Stücke (Leerraum, Anhänge) übernehmen die gemeinsame Formatierung der Nachbarn
        for k in pieces.indices where pieces[k].isNeutral {
            let prev = pieces[..<k].last { !$0.isNeutral }?.flags ?? .none
            let next = pieces[(k + 1)...].first { !$0.isNeutral }?.flags ?? .none
            if pieces[k].isBlank || !(prev == .none && next == .none) {
                pieces[k].flags = prev.intersect(next).intersect(pieces[k].isBlank ? Flags(bold: true, italic: true, strike: true, underline: true) : pieces[k].flags)
            }
        }
        // Marken setzen: Stapel offener Formate
        var out = ""
        var stack: [(kind: Int, mark: String)] = []      // 0 unterstrichen, 1 fett, 2 kursiv, 3 durchgestrichen
        func want(_ f: Flags) -> [Int] {
            var w: [Int] = []
            if f.underline { w.append(0) }
            if f.bold { w.append(1) }
            if f.italic { w.append(2) }
            if f.strike { w.append(3) }
            return w
        }
        func close(_ m: String) -> String { m == "<u>" ? "</u>" : m }
        for p in pieces {
            let w = want(p.flags)
            var keep = 0
            while keep < stack.count, w.contains(stack[keep].kind) { keep += 1 }
            while stack.count > keep { out += close(stack.removeLast().mark) }
            for k in w where !stack.contains(where: { $0.kind == k }) {
                // kursiv direkt an „**“ als „_“, sonst entstünde „***“
                let m = k == 0 ? "<u>" : k == 1 ? "**" : k == 2 ? (out.hasSuffix("*") ? "_" : "*") : "~~"
                out += m; stack.append((k, m))
            }
            switch p {
            case .text(let s, _): out += escape(s, all: escapeAll)
            case .code(let s, _): out += s.contains("`") ? "`` \(s) ``" : "`\(s)`"
            case .raw(let s, _): out += s
            case .link(let inner, let dest, _):
                let d = dest.contains(" ") || dest.contains(")") ? "<\(dest)>" : dest
                out += "[" + emit(inner, escapeAll: escapeAll) + "](" + d + ")"
            }
        }
        while let m = stack.popLast() { out += close(m.mark) }
        return out
    }

    private static func escape(_ s: String, all: Bool) -> String {
        var out = ""
        let a = Array(s)
        for (k, c) in a.enumerated() {
            let next: Character? = k + 1 < a.count ? a[k + 1] : nil
            if c == "\\", let n = next, isPunct(n) { out += "\\\\"; continue }
            if c == "\\", next == nil, all { out += "\\\\"; continue }
            if all, "*_`~[]<".contains(c) { out += "\\"; out.append(c); continue }
            out.append(c)
        }
        return out
    }

    // MARK: Vergleich

    /// Gleicher Text und gleiche Bedeutung (Formatierung, Links, Anhänge) – nackte URLs zählen wie Text.
    static func equal(_ a: NSAttributedString, _ b: NSAttributedString) -> Bool {
        guard a.string == b.string else { return false }
        var i = 0
        while i < a.length {
            let x = a.attributes(at: i, effectiveRange: nil), y = b.attributes(at: i, effectiveRange: nil)
            let blank = (a.string as NSString).character(at: i) == 32 || (a.string as NSString).character(at: i) == 9
            for k in [NSAttributedString.Key.hnBold, .hnItalic, .hnStrike, .hnUnderline, .hnCode] where (x[k] != nil) != (y[k] != nil) {
                if blank && k != .hnCode { continue }      // Formatierung auf Leerzeichen ist unsichtbar
                return false
            }
            let lx = x[.hnAutolink] != nil ? nil : x[.hnLink] as? String
            let ly = y[.hnAutolink] != nil ? nil : y[.hnLink] as? String
            if lx != ly { return false }
            if (x[.hnAttachment] as? AttachmentRef) != (y[.hnAttachment] as? AttachmentRef) { return false }
            i += 1
        }
        return true
    }
}

/// Noch nicht hochgeladener Anhang: `homenotes-pending:<uuid>/<name>` im Markdown, Datei liegt lokal.
nonisolated enum PendingAttachment {
    static let scheme = "homenotes-pending:"
}

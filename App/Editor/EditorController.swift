import UIKit
import SwiftUI
import Observation

/// Textansicht des Editors: Tastenkürzel wie in Apples Notizen, Einsetzen als Markdown, Breitenwechsel melden.
final class NoteTextView: UITextView {
    weak var controller: EditorController?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastWidth) > 1 {
            lastWidth = bounds.width
            controller?.widthChanged()
        }
        controller?.layoutDateLabel()
    }

    override func paste(_ sender: Any?) {
        if controller?.pastePlain() == true { return }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) { return isEditable && UIPasteboard.general.hasStrings || super.canPerformAction(action, withSender: sender) }
        return super.canPerformAction(action, withSender: sender)
    }

    override var keyCommands: [UIKeyCommand]? {
        guard isEditable else { return nil }
        func k(_ input: String, _ mods: UIKeyModifierFlags, _ title: String, _ sel: Selector) -> UIKeyCommand {
            let c = UIKeyCommand(title: title, action: sel, input: input, modifierFlags: mods)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        return [
            k("\t", [], String(localized: "Einrücken"), #selector(kTab)),
            k("\t", .shift, String(localized: "Ausrücken"), #selector(kShiftTab)),
            k("]", .command, String(localized: "Einrücken"), #selector(kTab)),
            k("[", .command, String(localized: "Ausrücken"), #selector(kShiftTab)),
            k("b", .command, String(localized: "Fett"), #selector(kBold)),
            k("i", .command, String(localized: "Kursiv"), #selector(kItalic)),
            k("u", .command, String(localized: "Unterstrichen"), #selector(kUnderline)),
            k("t", [.command, .shift], String(localized: "Titel"), #selector(kTitle)),
            k("h", [.command, .shift], String(localized: "Überschrift"), #selector(kHeading)),
            k("j", [.command, .shift], String(localized: "Unterüberschrift"), #selector(kSub)),
            k("b", [.command, .shift], String(localized: "Text"), #selector(kBody)),
            k("m", [.command, .shift], String(localized: "Dicktengleich"), #selector(kMono)),
            k("7", [.command, .shift], String(localized: "Aufzählung"), #selector(kBullet)),
            k("8", [.command, .shift], String(localized: "Spiegelstrich"), #selector(kDash)),
            k("9", [.command, .shift], String(localized: "Nummeriert"), #selector(kNumber)),
            k("l", [.command, .shift], String(localized: "Checkliste"), #selector(kCheck)),
            k("u", [.command, .shift], String(localized: "Als erledigt markieren"), #selector(kDone)),
            k("k", .command, String(localized: "Link hinzufügen"), #selector(kLink)),
        ]
    }

    @objc private func kTab() { if controller?.indent(1) != true { insertText("\t") } }
    @objc private func kShiftTab() { _ = controller?.indent(-1) }
    @objc private func kBold() { controller?.toggleInline(.hnBold) }
    @objc private func kItalic() { controller?.toggleInline(.hnItalic) }
    @objc private func kUnderline() { controller?.toggleInline(.hnUnderline) }
    @objc private func kTitle() { controller?.setBlock(.title) }
    @objc private func kHeading() { controller?.setBlock(.heading) }
    @objc private func kSub() { controller?.setBlock(.subheading) }
    @objc private func kBody() { controller?.setBlock(.body) }
    @objc private func kMono() { controller?.setBlock(.mono) }
    @objc private func kBullet() { controller?.setBlock(.bullet) }
    @objc private func kDash() { controller?.setBlock(.dash) }
    @objc private func kNumber() { controller?.setBlock(.number) }
    @objc private func kCheck() { controller?.setBlock(.check) }
    @objc private func kDone() { controller?.toggleCheckedAtSelection() }
    @objc private func kLink() { controller?.beginLinkEdit() }
}

struct FormatState: Equatable {
    var kind: BlockKind = .body
    var bold = false, italic = false, underline = false, strike = false
}

struct TableEdit: Identifiable { let id = UUID(); let original: TableBox; let isNew: Bool }
struct LinkEdit: Identifiable { let id = UUID(); var url: String; var text: String; var range: NSRange }
struct AttachmentTap: Identifiable { let id = UUID(); let ref: AttachmentRef; let range: NSRange }

/// Steuert den Editor: Markdown laden/speichern, Absatzformate, Listen und Checklisten, Tabellen, Anhänge.
@MainActor @Observable
final class EditorController: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
    var noteId = 0
    var readonly = false
    var isEditing = false
    var showFormat = false
    var state = FormatState()
    var tableEdit: TableEdit?
    var linkEdit: LinkEdit?
    var attachmentTap: AttachmentTap?
    var previewURL: URL?
    var showCreated = false
    var hasChecklist = false

    @ObservationIgnored let textView = NoteTextView(usingTextLayoutManager: true)
    @ObservationIgnored weak var store: NoteStore?
    @ObservationIgnored var newNoteStyle: BlockKind = .title
    @ObservationIgnored var onSaved: (() -> Void)?
    @ObservationIgnored private var lastMarkdown = ""
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var suppress = false
    @ObservationIgnored private var touchOnSpecial = false
    @ObservationIgnored private var specialTouchAt = Date.distantPast
    @ObservationIgnored private var pendingEdit: NSRange?
    @ObservationIgnored private var previousSelection = NSRange(location: 0, length: 0)
    @ObservationIgnored private var images: [String: UIImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private let dateLabel = UILabel()
    @ObservationIgnored private var modified: Date?
    @ObservationIgnored private var created: Date?
    @ObservationIgnored private lazy var formatContainer: UIView = makeHost(FormatPanel(controller: self), height: 290)
    @ObservationIgnored private lazy var accessoryContainer: UIView = makeHost(AccessoryBar(controller: self), height: 58, transparent: true)

    private var ts: NSTextStorage { textView.textStorage }
    private var ns: NSString { ts.string as NSString }

    override init() {
        super.init()
        configure()
    }

    private func configure() {
        let tv = textView
        tv.controller = self
        tv.delegate = self
        tv.backgroundColor = .systemBackground
        tv.font = Styler.baseFont(.body)
        tv.textContainerInset = UIEdgeInsets(top: 46, left: 18, bottom: 140, right: 18)
        tv.textContainer.lineFragmentPadding = 0
        tv.alwaysBounceVertical = true
        tv.keyboardDismissMode = .interactive
        tv.isFindInteractionEnabled = true
        tv.allowsEditingTextAttributes = false
        tv.linkTextAttributes = [.foregroundColor: Styler.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        tv.accessibilityIdentifier = "editor"
        tv.inputAccessoryView = accessoryContainer
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        tv.addGestureRecognizer(tap)
        dateLabel.font = .preferredFont(forTextStyle: .footnote)
        dateLabel.textColor = .secondaryLabel
        dateLabel.textAlignment = .center
        dateLabel.isUserInteractionEnabled = true
        dateLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dateTapped)))
        tv.addSubview(dateLabel)
    }

    private func makeHost<V: View>(_ v: V, height: CGFloat, transparent: Bool = false) -> UIView {
        let host = UIHostingController(rootView: v)
        host.sizingOptions = []
        let container = UIInputView(frame: CGRect(x: 0, y: 0, width: 400, height: height), inputViewStyle: transparent ? .default : .keyboard)
        container.allowsSelfSizing = false
        if transparent { container.backgroundColor = .clear }
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        objc_setAssociatedObject(container, &Self.hostKey, host, .OBJC_ASSOCIATION_RETAIN)
        return container
    }
    nonisolated(unsafe) private static var hostKey: UInt8 = 0

    // MARK: Laden / Speichern

    var contentWidth: CGFloat {
        let w = textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right
        if w > 50 { return w }
        let screenW = textView.window?.windowScene?.screen.bounds.width ?? 393
        return screenW - textView.textContainerInset.left - textView.textContainerInset.right
    }

    func load(markdown: String, modified: Date?, created: Date?) {
        lastMarkdown = markdown
        self.modified = modified
        self.created = created
        var paragraphs = MarkdownCodec.parse(markdown)
        if markdown.isEmpty { paragraphs = [Paragraph(kind: newNoteStyle)] }
        let attr = Styler.attributed(paragraphs, width: contentWidth)
        suppress = true
        textView.attributedText = attr
        textView.isEditable = !readonly
        let first = paragraphs.first ?? Paragraph()
        textView.typingAttributes = Styler.visual(Styler.paragraphKeys(first.kind, indent: 0, checked: false, level: first.level, fence: nil))
        suppress = false
        textView.undoManager?.removeAllActions()
        updateDateLabel()
        loadAttachments()
        updateState()
    }

    /// Änderungen vom Server übernehmen (nur wenn hier nichts Ungesichertes wartet).
    func reloadIfChanged(markdown: String, modified: Date?) {
        guard saveTask == nil, markdown != lastMarkdown, textView.markedTextRange == nil else { return }
        let sel = textView.selectedRange
        load(markdown: markdown, modified: modified, created: created)
        textView.selectedRange = NSRange(location: min(sel.location, ts.length), length: 0)
    }

    func currentMarkdown() -> String { MarkdownCodec.serialize(Styler.paragraphs(from: ts)) }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard !readonly, let store else { return }
        let md = currentMarkdown()
        guard md != lastMarkdown else { return }
        lastMarkdown = md
        noteId = store.resolve(noteId)
        store.updateContent(noteId, md)
        modified = Date()
        updateDateLabel()
        onSaved?()
    }

    // MARK: Datum oben

    func layoutDateLabel() {
        dateLabel.frame = CGRect(x: 16, y: 14, width: max(0, textView.bounds.width - 32), height: 20)
    }

    private func updateDateLabel() {
        let f: (Date) -> String = { $0.formatted(.dateTime.day().month(.wide).year().hour().minute()) }
        if showCreated, let c = created { dateLabel.text = String(localized: "Erstellt: \(f(c))") }
        else if let m = modified { dateLabel.text = f(m) }
        else { dateLabel.text = nil }
    }

    @objc private func dateTapped() {
        guard created != nil else { return }
        showCreated.toggle()
        updateDateLabel()
    }

    // MARK: Absätze

    struct PInfo {
        var range: NSRange
        var kind: BlockKind
        var indent: Int
        var checked: Bool
        var level: Int
        var fence: String?
        var markerLength: Int
        var content: NSRange          // ohne Zeichen und Zeilenumbruch
    }

    private func info(_ pr: NSRange) -> PInfo {
        let hasNL = pr.length > 0 && ns.character(at: NSMaxRange(pr) - 1) == 10
        let end = NSMaxRange(pr) - (hasNL ? 1 : 0)
        let a: [NSAttributedString.Key: Any] = pr.length > 0 ? ts.attributes(at: pr.location, effectiveRange: nil) : textView.typingAttributes
        var m = 0
        while pr.location + m < end, ts.attribute(.hnMarker, at: pr.location + m, effectiveRange: nil) != nil { m += 1 }
        return PInfo(range: pr, kind: BlockKind(rawValue: a[.hnBlock] as? String ?? "") ?? .body,
                     indent: a[.hnIndent] as? Int ?? 0, checked: a[.hnChecked] as? Bool ?? false,
                     level: a[.hnLevel] as? Int ?? 0, fence: a[.hnFence] as? String,
                     markerLength: m, content: NSRange(location: pr.location + m, length: end - pr.location - m))
    }

    private func paragraph(at loc: Int) -> NSRange {
        ns.paragraphRange(for: NSRange(location: min(max(0, loc), ns.length), length: 0))
    }

    /// Alle Absätze, die die Auswahl berührt.
    private func paragraphs(in r: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var loc = r.location
        let end = NSMaxRange(r)
        repeat {
            let pr = paragraph(at: loc)
            out.append(pr)
            if NSMaxRange(pr) <= loc { break }
            loc = NSMaxRange(pr)
        } while loc < end
        if out.isEmpty || (ns.length > 0 && end == ns.length && ns.character(at: ns.length - 1) == 10 && r.length == 0 && r.location == ns.length) {
            out = [NSRange(location: ns.length, length: 0)]
        }
        return out
    }

    private func number(for loc: Int, indent: Int) -> Int {
        var n = 1
        var p = loc
        while p > 0 {
            let prev = paragraph(at: p - 1)
            let i = info(prev)
            if i.kind == .number && i.indent == indent { n += 1 }
            else if !(i.kind.isList && i.indent > indent) { break }
            p = prev.location
        }
        return n
    }

    private func setParagraph(_ pr: NSRange, kind: BlockKind? = nil, indent: Int? = nil, checked: Bool? = nil) {
        let i = info(pr)
        let k = kind ?? i.kind
        let keys = Styler.paragraphKeys(k, indent: indent ?? i.indent, checked: checked ?? (kind != nil && kind != i.kind ? false : i.checked),
                                        level: k == i.kind ? i.level : 0, fence: k == .mono ? i.fence : nil)
        if pr.length == 0 {
            var t = textView.typingAttributes
            for key in Styler.paragraphKeyList { t[key] = nil }
            for (key, v) in keys { t[key] = v }
            textView.typingAttributes = Styler.visual(t)
            return
        }
        for key in Styler.paragraphKeyList { ts.removeAttribute(key, range: pr) }
        ts.addAttributes(keys, range: pr)
    }

    // MARK: Aufräumen nach jeder Änderung

    /// Aufzählungszeichen, Nummern, Kreise, Schriften der betroffenen Absätze richtigstellen.
    func normalize(_ range: NSRange? = nil) {
        guard textView.markedTextRange == nil else { return }
        let wasSuppressed = suppress
        suppress = true
        defer { suppress = wasSuppressed }
        var sel = textView.selectedRange
        let r = range.map { NSRange(location: min($0.location, ns.length), length: min($0.length, ns.length - min($0.location, ns.length))) }
        var loc = r.map { paragraph(at: $0.location).location } ?? 0
        var end = r.map { NSMaxRange(paragraph(at: NSMaxRange($0))) } ?? ns.length
        ts.beginEditing()
        var guardCount = 0
        while guardCount < 200_000 {
            guardCount += 1
            if loc >= ns.length {
                // leerer letzter Absatz nach „\n“ (nur mit Tipp-Attributen) – Zeichen nur, wenn der Cursor dort steht
                if ns.length == 0 || ns.character(at: ns.length - 1) == 10, sel.location == ns.length {
                    _ = normalizeParagraph(NSRange(location: ns.length, length: 0), sel: &sel)
                }
                break
            }
            let pr = paragraph(at: loc)
            let before = ns.length
            let next = normalizeParagraph(pr, sel: &sel)
            end += ns.length - before
            if next == pr.location { continue }          // Absatz wurde geteilt → erneut prüfen
            loc = next
            if loc >= end, loc < ns.length {
                // Nummerierung der folgenden Liste mitziehen
                let i = info(paragraph(at: loc))
                if i.kind == .number || (i.kind.isList && i.indent > 0) { end = NSMaxRange(paragraph(at: loc)) } else { break }
            }
        }
        ts.endEditing()
        textView.selectedRange = NSRange(location: min(sel.location, ns.length), length: min(sel.length, ns.length - min(sel.location, ns.length)))
    }

    private func replace(_ r: NSRange, with s: NSAttributedString, sel: inout NSRange) {
        ts.replaceCharacters(in: r, with: s)
        let d = s.length - r.length
        func adj(_ p: Int) -> Int {
            if p >= NSMaxRange(r) { return p + d }
            if p > r.location { return r.location + s.length }
            return p
        }
        let a = adj(sel.location), b = adj(NSMaxRange(sel))
        sel = NSRange(location: a, length: max(0, b - a))
    }

    /// Gibt die Position nach dem Absatz zurück (oder den Absatzanfang, wenn er neu geprüft werden muss).
    private func normalizeParagraph(_ pr0: NSRange, sel: inout NSRange) -> Int {
        var pr = pr0
        var i = info(pr)
        // 1. verirrte Zeichen (nach dem Zusammenfügen zweier Absätze) entfernen
        let tail = NSRange(location: i.content.location, length: NSMaxRange(pr) - i.content.location)
        var strays: [NSRange] = []
        if tail.length > 0 {
            ts.enumerateAttribute(.hnMarker, in: tail) { v, r, _ in if v != nil { strays.append(r) } }
        }
        for r in strays.reversed() {
            replace(r, with: NSAttributedString(), sel: &sel)
            pr.length -= r.length
        }
        i = info(pr)
        // 2. Tabelle: Absatz enthält nur das Tabellenzeichen
        if i.kind == .table {
            var tableAt: Int?
            if i.content.length > 0 {
                ts.enumerateAttribute(.hnTable, in: i.content) { v, r, stop in if v != nil { tableAt = r.location; stop.pointee = true } }
            }
            if let t = tableAt {
                if NSMaxRange(i.content) > t + 1 {
                    // Text hinter der Tabelle → eigener Absatz
                    let nl = NSAttributedString(string: "\n", attributes: ts.attributes(at: t, effectiveRange: nil))
                    replace(NSRange(location: t + 1, length: 0), with: nl, sel: &sel)
                    let rest = NSRange(location: t + 2, length: NSMaxRange(paragraph(at: t + 2)) - (t + 2))
                    for k in Styler.paragraphKeyList { ts.removeAttribute(k, range: rest) }
                    ts.addAttributes(Styler.paragraphKeys(.body, indent: 0, checked: false, level: 0, fence: nil), range: rest)
                    ts.removeAttribute(.hnTable, range: rest)
                    return pr.location
                }
                if t > i.content.location {
                    // Text vor der Tabelle → eigener Absatz
                    let beforeR = NSRange(location: i.content.location, length: t - i.content.location)
                    for k in Styler.paragraphKeyList { ts.removeAttribute(k, range: beforeR) }
                    ts.addAttributes(Styler.paragraphKeys(.body, indent: 0, checked: false, level: 0, fence: nil), range: beforeR)
                    let nl = NSAttributedString(string: "\n", attributes: Styler.visual(Styler.paragraphKeys(.body, indent: 0, checked: false, level: 0, fence: nil)))
                    replace(NSRange(location: t, length: 0), with: nl, sel: &sel)
                    return pr.location
                }
            } else {
                setParagraph(pr, kind: .body)
                i = info(pr)
            }
        }
        // 3. Aufzählungszeichen
        let keys = Styler.paragraphKeys(i.kind, indent: i.indent, checked: i.checked, level: i.level, fence: i.fence)
        if i.kind.hasMarker {
            let n = i.kind == .number ? number(for: pr.location, indent: i.indent) : 0
            let id = Styler.markerId(i.kind, number: n, checked: i.checked)
            let existing = i.markerLength > 0 ? ts.attribute(.hnMarker, at: pr.location, effectiveRange: nil) as? String : nil
            let existingStyle = i.markerLength > 0 ? ts.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle : nil
            if existing != id || existingStyle != Styler.paragraphStyle(i.kind, indent: i.indent) {
                let m = Styler.marker(i.kind, indent: i.indent, checked: i.checked, number: n, paragraph: keys)
                replace(NSRange(location: pr.location, length: i.markerLength), with: m, sel: &sel)
                pr.length += m.length - i.markerLength
                i.markerLength = m.length
            }
        } else if i.markerLength > 0 {
            replace(NSRange(location: pr.location, length: i.markerLength), with: NSAttributedString(), sel: &sel)
            pr.length -= i.markerLength
            i.markerLength = 0
        }
        // 4. Schrift und Einzug des Inhalts
        let content = NSRange(location: pr.location + i.markerLength, length: pr.length - i.markerLength)
        if content.length > 0 {
            var updates: [(NSRange, [NSAttributedString.Key: Any])] = []
            ts.enumerateAttributes(in: content) { a, r, _ in
                if a[.hnMarker] != nil { return }
                var sem = keys
                for k in Inline.semanticKeys { if let v = a[k] { sem[k] = v } }
                if let t = a[.hnTable] { sem[.hnTable] = t }
                var vis = Styler.visual(sem)
                if let att = a[.attachment] { vis[.attachment] = att }
                else if let ref = a[.hnAttachment] as? AttachmentRef { vis[.attachment] = attachment(for: ref) }
                if !NSDictionary(dictionary: a).isEqual(to: vis) { updates.append((r, vis)) }
            }
            for (r, v) in updates { ts.setAttributes(v, range: r) }
        }
        if pr.length == 0 { return ns.length + 1 }
        return NSMaxRange(pr)
    }

    // MARK: Tippen

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        if touchOnSpecial { touchOnSpecial = false; return false }
        return !readonly
    }

    func textViewDidBeginEditing(_ textView: UITextView) { isEditing = true }

    func textViewDidEndEditing(_ textView: UITextView) {
        isEditing = false
        if showFormat { showFormat = false; textView.inputView = nil }
        flush()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if readonly { return false }
        if suppress { return true }
        if text == "\n" { handleReturn(range); return false }
        if text == " ", range.length == 0, autoList(at: range.location) { return false }
        if text.isEmpty, range.length == 1, !handleBackspace(range) { return false }
        pendingEdit = NSRange(location: range.location, length: (text as NSString).length)
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !suppress, textView.markedTextRange == nil else { return }
        normalize(pendingEdit ?? textView.selectedRange)
        pendingEdit = nil
        scheduleSave()
        updateState()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !suppress else { return }
        // Tippen auf Kreis/Bild/Tabelle: Cursor bleibt, wo er war
        if Date().timeIntervalSince(specialTouchAt) < 0.6, textView.selectedRange != previousSelection, previousSelection.location <= ns.length {
            suppress = true
            textView.selectedRange = previousSelection
            suppress = false
            return
        }
        let sel = textView.selectedRange
        if sel.length == 0, ns.length > 0 {
            let pr = paragraph(at: sel.location)
            let i = info(pr)
            if i.markerLength > 0, sel.location >= pr.location, sel.location < i.content.location {
                // Cursor nie zwischen Aufzählungszeichen: nach links springt er in den vorigen Absatz
                let goingLeft = previousSelection.location == i.content.location && sel.location < previousSelection.location
                let target = goingLeft && pr.location > 0 ? pr.location - 1 : i.content.location
                suppress = true
                textView.selectedRange = NSRange(location: target, length: 0)
                suppress = false
            }
        }
        previousSelection = textView.selectedRange
        updateTypingAttributes()
        updateState()
    }

    private func updateTypingAttributes() {
        let sel = textView.selectedRange
        let pr = paragraph(at: sel.location)
        let i = info(pr)
        var src: [NSAttributedString.Key: Any]
        if sel.location > i.content.location, sel.location - 1 < ns.length { src = ts.attributes(at: sel.location - 1, effectiveRange: nil) }
        else if i.content.length > 0 { src = ts.attributes(at: i.content.location, effectiveRange: nil) }
        else if pr.length > 0 { src = ts.attributes(at: pr.location, effectiveRange: nil) }
        else { src = textView.typingAttributes }
        var sem = Styler.semantic(src)
        sem[.hnAttachment] = nil; sem[.hnAutolink] = nil
        // Link nur fortsetzen, wenn der Cursor mitten darin steht
        if let l = sem[.hnLink] as? String {
            let nextLink = sel.location < ns.length ? ts.attribute(.hnLink, at: sel.location, effectiveRange: nil) as? String : nil
            if nextLink != l { sem[.hnLink] = nil }
        }
        if (BlockKind(rawValue: sem[.hnBlock] as? String ?? "") ?? .body) == .table {
            sem = Styler.paragraphKeys(.body, indent: 0, checked: false, level: 0, fence: nil)
        }
        textView.typingAttributes = Styler.visual(sem)
    }

    private func updateState() {
        let a = textView.typingAttributes
        let sel = textView.selectedRange
        var s = FormatState()
        s.kind = BlockKind(rawValue: a[.hnBlock] as? String ?? "") ?? .body
        if sel.length > 0 {
            s.bold = all(.hnBold, in: sel); s.italic = all(.hnItalic, in: sel)
            s.underline = all(.hnUnderline, in: sel); s.strike = all(.hnStrike, in: sel)
            s.kind = info(paragraph(at: sel.location)).kind
        } else {
            s.bold = a[.hnBold] != nil; s.italic = a[.hnItalic] != nil
            s.underline = a[.hnUnderline] != nil; s.strike = a[.hnStrike] != nil
        }
        if s != state { state = s }
        let hc = ts.string.contains("\u{FFFC}") && checkCount() > 0
        if hc != hasChecklist { hasChecklist = hc }
    }

    private func checkCount() -> Int {
        var n = 0
        ts.enumerateAttribute(.hnMarker, in: NSRange(location: 0, length: ts.length)) { v, _, _ in
            if let s = v as? String, s.hasPrefix("check") { n += 1 }
        }
        return n
    }

    private func all(_ key: NSAttributedString.Key, in r: NSRange) -> Bool {
        var ok = true
        var any = false
        ts.enumerateAttributes(in: r) { a, rr, stop in
            if a[.hnMarker] != nil { return }
            let s = ns.substring(with: rr)
            if s.allSatisfy({ $0 == "\n" }) { return }
            any = true
            if a[key] == nil { ok = false; stop.pointee = true }
        }
        return ok && any
    }

    private func handleReturn(_ range: NSRange) {
        let pr = paragraph(at: range.location)
        let i = info(pr)
        if i.kind.hasMarker, i.content.length == 0, range.length == 0 {
            // leerer Listenpunkt: erst ausrücken, dann Liste beenden (wie Apple)
            perform {
                if i.indent > 0 { setParagraph(pr, indent: i.indent - 1) } else { setParagraph(pr, kind: .body) }
                normalize(pr)
            }
            return
        }
        let atStart = range.location == i.content.location && range.length == 0 && i.content.length > 0
        suppress = true
        textView.insertText("\n")
        suppress = false
        let newLoc = textView.selectedRange.location
        let npr = paragraph(at: newLoc)
        let n = info(npr)
        let headingLike = [BlockKind.title, .heading, .subheading, .table].contains(i.kind)
        if atStart, i.kind.hasMarker {
            // Return am Anfang eines Eintrags: leerer Eintrag darüber, dieser behält seinen Haken (wie Apple)
            setParagraph(paragraph(at: pr.location), checked: false)
        } else if headingLike, n.content.length == 0 || i.kind == .table {
            setParagraph(npr, kind: .body)
        } else if i.kind == .check {
            setParagraph(npr, checked: false)
        }
        if npr.length == 0 || n.content.length == 0 {
            let k = headingLike ? BlockKind.body : i.kind
            textView.typingAttributes = Styler.visual(Styler.paragraphKeys(k, indent: i.indent, checked: false, level: 0, fence: k == .mono ? i.fence : nil))
        }
        normalize(NSRange(location: pr.location, length: max(0, NSMaxRange(npr) - pr.location)))
        textView.scrollRangeToVisible(textView.selectedRange)
        scheduleSave()
        updateState()
    }

    /// „- “, „* “, „1. “ oder „[] “ am Zeilenanfang macht eine Liste daraus (wie Apple).
    private func autoList(at loc: Int) -> Bool {
        let pr = paragraph(at: loc)
        let i = info(pr)
        guard i.kind == .body, loc > i.content.location, loc - i.content.location <= 3 else { return false }
        let prefix = ns.substring(with: NSRange(location: i.content.location, length: loc - i.content.location))
        let map: [String: BlockKind] = ["-": .dash, "*": .bullet, "•": .bullet, "1.": .number, "[]": .check]
        guard let kind = map[prefix] else { return false }
        perform {
            ts.replaceCharacters(in: NSRange(location: i.content.location, length: (prefix as NSString).length), with: "")
            let start = i.content.location
            textView.selectedRange = NSRange(location: start, length: 0)
            setParagraph(paragraph(at: start), kind: kind)
            if paragraph(at: start).length == 0 || ns.length == start {
                textView.typingAttributes = Styler.visual(Styler.paragraphKeys(kind, indent: 0, checked: false, level: 0, fence: nil))
            }
            normalize(NSRange(location: start, length: 0))
        }
        return true
    }

    /// `false` = selbst erledigt (Listenformat entfernt).
    private func handleBackspace(_ range: NSRange) -> Bool {
        let pr = paragraph(at: range.location)
        let i = info(pr)
        guard i.markerLength > 0, range.location >= pr.location, range.location < i.content.location else { return true }
        perform {
            setParagraph(pr, kind: .body)
            normalize(pr)
            textView.selectedRange = NSRange(location: pr.location, length: 0)
        }
        return false
    }

    // MARK: Formatieren (mit Widerrufen)

    private func perform(_ body: () -> Void) {
        let before = NSAttributedString(attributedString: ts)
        let selBefore = textView.selectedRange
        body()
        registerUndo(before, selBefore)
        scheduleSave()
        updateTypingAttributes()
        updateState()
    }

    private func registerUndo(_ snap: NSAttributedString, _ sel: NSRange) {
        guard let um = textView.undoManager else { return }
        um.registerUndo(withTarget: self) { c in
            MainActor.assumeIsolated {
                let redo = NSAttributedString(attributedString: c.ts)
                let redoSel = c.textView.selectedRange
                c.restore(snap, sel)
                c.registerUndo(redo, redoSel)
            }
        }
    }

    private func restore(_ s: NSAttributedString, _ sel: NSRange) {
        suppress = true
        ts.setAttributedString(s)
        textView.selectedRange = NSRange(location: min(sel.location, ts.length), length: min(sel.length, ts.length - min(sel.location, ts.length)))
        suppress = false
        scheduleSave()
        updateTypingAttributes()
        updateState()
    }

    func setBlock(_ kind: BlockKind) {
        guard !readonly else { return }
        let sel = textView.selectedRange
        let prs = paragraphs(in: sel)
        let infos = prs.map(info)
        let toggles = kind.hasMarker || kind == .mono
        let allSame = infos.allSatisfy { $0.kind == kind }
        perform {
            for pr in prs.reversed() {
                setParagraph(pr, kind: toggles && allSame ? .body : kind)
            }
            let whole = NSRange(location: prs.first!.location, length: NSMaxRange(prs.last!) - prs.first!.location)
            normalize(whole)
        }
    }

    func toggleInline(_ key: NSAttributedString.Key) {
        guard !readonly else { return }
        let sel = textView.selectedRange
        if sel.length == 0 {
            var t = Styler.semantic(textView.typingAttributes)
            t[key] = t[key] == nil ? true : nil
            textView.typingAttributes = Styler.visual(t)
            updateState()
            return
        }
        let on = !all(key, in: sel)
        perform {
            var ranges: [NSRange] = []
            ts.enumerateAttributes(in: sel) { a, r, _ in if a[.hnMarker] == nil { ranges.append(r) } }
            for r in ranges { if on { ts.addAttribute(key, value: true, range: r) } else { ts.removeAttribute(key, range: r) } }
            normalize(sel)
        }
    }

    /// Einrücken nur für Listen und Zitate (Markdown kennt keinen Einzug für Fließtext).
    @discardableResult
    func indent(_ delta: Int) -> Bool {
        guard !readonly else { return false }
        let prs = paragraphs(in: textView.selectedRange)
        let infos = prs.map(info)
        guard infos.contains(where: { $0.kind.isList }) else { return false }
        perform {
            for (pr, i) in zip(prs, infos).reversed() where i.kind.isList {
                setParagraph(pr, indent: min(8, max(0, i.indent + delta)))
            }
            normalize(NSRange(location: prs.first!.location, length: NSMaxRange(prs.last!) - prs.first!.location))
        }
        return true
    }

    func toggleCheckedAtSelection() {
        let pr = paragraph(at: textView.selectedRange.location)
        let i = info(pr)
        if i.kind == .check { toggleChecked(pr) } else { setBlock(.check) }
    }

    private func toggleChecked(_ pr: NSRange) {
        guard !readonly else { return }
        let i = info(pr)
        guard i.kind == .check else { return }
        let sel = textView.selectedRange
        perform {
            setParagraph(pr, checked: !i.checked)
            normalize(pr)
            textView.selectedRange = sel
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Checklisten-Aktionen („Mehr“)

    enum ChecklistAction { case checkAll, uncheckAll, moveCheckedDown, removeChecked }

    func checklist(_ action: ChecklistAction) {
        guard !readonly else { return }
        var paras = Styler.paragraphs(from: ts)
        switch action {
        case .checkAll: for k in paras.indices where paras[k].kind == .check { paras[k].checked = true }
        case .uncheckAll: for k in paras.indices where paras[k].kind == .check { paras[k].checked = false }
        case .removeChecked: paras.removeAll { $0.kind == .check && $0.checked }
        case .moveCheckedDown:
            var out: [Paragraph] = []
            var k = 0
            while k < paras.count {
                if paras[k].kind == .check {
                    var j = k
                    while j < paras.count, paras[j].kind == .check { j += 1 }
                    let block = paras[k..<j]
                    out += block.filter { !$0.checked } + block.filter(\.checked)
                    k = j
                } else { out.append(paras[k]); k += 1 }
            }
            paras = out
        }
        if paras.isEmpty { paras = [Paragraph()] }
        replaceAll(paras)
    }

    private func replaceAll(_ paras: [Paragraph]) {
        perform {
            let sel = textView.selectedRange
            let a = Styler.attributed(paras, width: contentWidth)
            suppress = true
            ts.setAttributedString(a)
            textView.selectedRange = NSRange(location: min(sel.location, ts.length), length: 0)
            suppress = false
            loadAttachments()
        }
    }

    // MARK: Tabellen

    func insertTable() {
        guard !readonly else { return }
        let box = TableBox(rows: [["", ""], ["", ""], ["", ""]])
        insertBlock(tableString(box))
        tableEdit = TableEdit(original: box, isNew: true)
    }

    private func tableString(_ box: TableBox) -> NSAttributedString {
        var a = Styler.visual(Styler.paragraphKeys(.table, indent: 0, checked: false, level: 0, fence: nil))
        a[.hnTable] = box
        let s = NSMutableAttributedString(attachment: NSTextAttachment(image: TableRenderer.image(box, width: contentWidth)))
        s.addAttributes(a, range: NSRange(location: 0, length: s.length))
        return s
    }

    /// Ein Block (Tabelle, Bild) als eigener Absatz an der Cursorposition.
    private func insertBlock(_ block: NSAttributedString) {
        perform {
            if !textView.isFirstResponder { textView.selectedRange = NSRange(location: ts.length, length: 0) }
            let sel = textView.selectedRange
            let pr = paragraph(at: sel.location)
            let i = info(pr)
            let body = Styler.visual(Styler.paragraphKeys(.body, indent: 0, checked: false, level: 0, fence: nil))
            let s = NSMutableAttributedString()
            if i.content.length > 0, sel.location > i.content.location {
                s.append(NSAttributedString(string: "\n", attributes: ts.attributes(at: max(pr.location, sel.location - 1), effectiveRange: nil)))
            }
            s.append(block)
            // Zeilenumbruch danach nur, wenn nicht ohnehin einer folgt (sonst entstünde eine Leerzeile)
            let end = NSMaxRange(sel)
            if end >= ns.length || ns.character(at: end) != 10 || sel.location > i.content.location && NSMaxRange(sel) < NSMaxRange(i.content) {
                s.append(NSAttributedString(string: "\n", attributes: body))
            }
            suppress = true
            ts.replaceCharacters(in: sel, with: s)
            textView.selectedRange = NSRange(location: sel.location + s.length, length: 0)
            suppress = false
            normalize(NSRange(location: pr.location, length: s.length + 1))
        }
    }

    func editTable(_ box: TableBox) { tableEdit = TableEdit(original: box, isNew: false) }

    /// Ergebnis des Tabellen-Editors übernehmen.
    func applyTable(original: TableBox, result: TableBox?, convertToText: Bool = false) {
        guard let r = tableRange(for: original) else { return }
        perform {
            if convertToText {
                let t = result ?? original
                let lines = t.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
                let body = Styler.visual(Styler.paragraphKeys(.body, indent: 0, checked: false, level: 0, fence: nil))
                ts.replaceCharacters(in: r, with: NSAttributedString(string: lines, attributes: body))
            } else if let result {
                ts.replaceCharacters(in: r, with: tableString(result))
            } else {
                // löschen samt Zeilenumbruch
                var del = r
                if NSMaxRange(r) < ts.length, ns.character(at: NSMaxRange(r)) == 10 { del.length += 1 }
                ts.replaceCharacters(in: del, with: "")
            }
            normalize(NSRange(location: r.location, length: 1))
        }
    }

    private func tableRange(for box: TableBox) -> NSRange? {
        var out: NSRange?
        ts.enumerateAttribute(.hnTable, in: NSRange(location: 0, length: ts.length)) { v, r, stop in
            if let b = v as? TableBox, b === box { out = r; stop.pointee = true }
        }
        return out
    }

    // MARK: Anhänge

    func insertAttachment(path: String, name: String) {
        let ref = AttachmentRef(path: path, name: name, isImage: AttachmentRef.looksLikeImage(path))
        var a = Styler.visual(Styler.paragraphKeys(.body, indent: 0, checked: false, level: 0, fence: nil))
        a[.hnAttachment] = ref
        a[.attachment] = AttachmentViews.placeholder(ref, width: contentWidth)
        insertBlock(NSAttributedString(string: "\u{FFFC}", attributes: a))
        loadAttachments()
        flush()
    }

    private func attachment(for ref: AttachmentRef) -> NSTextAttachment {
        if ref.isImage, let img = images[ref.path] { return AttachmentViews.imageAttachment(img, width: contentWidth) }
        defer { loadAttachments() }
        return AttachmentViews.placeholder(ref, width: contentWidth)
    }

    func loadAttachments() {
        guard let store else { return }
        var refs: [AttachmentRef] = []
        ts.enumerateAttribute(.hnAttachment, in: NSRange(location: 0, length: ts.length)) { v, _, _ in
            if let r = v as? AttachmentRef, r.isImage { refs.append(r) }
        }
        for ref in refs {
            if let img = images[ref.path] { apply(img, for: ref, onlyPlaceholders: true); continue }
            guard !loading.contains(ref.path) else { continue }
            loading.insert(ref.path)
            let id = store.resolve(noteId)
            Task { [weak self] in
                guard let url = try? await store.attachmentFile(note: id, path: ref.path) else {
                    self?.loading.remove(ref.path); return
                }
                let img = await Task.detached { AttachmentViews.downsample(url, maxPixel: 2400) }.value
                guard let self else { return }
                self.loading.remove(ref.path)
                if let img { self.images[ref.path] = img; self.apply(img, for: ref, onlyPlaceholders: false) }
            }
        }
    }

    private func apply(_ img: UIImage, for ref: AttachmentRef, onlyPlaceholders: Bool) {
        let w = contentWidth
        var ranges: [NSRange] = []
        ts.enumerateAttribute(.hnAttachment, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            if (v as? AttachmentRef)?.path == ref.path { ranges.append(r) }
        }
        guard !ranges.isEmpty else { return }
        ts.beginEditing()
        for r in ranges {
            if onlyPlaceholders, let att = ts.attribute(.attachment, at: r.location, effectiveRange: nil) as? NSTextAttachment,
               abs(att.bounds.width - min(w, img.size.width)) < 2 { continue }
            ts.addAttribute(.attachment, value: AttachmentViews.imageAttachment(img, width: w), range: r)
        }
        ts.endEditing()
    }

    func widthChanged() {
        guard ts.length > 0 else { return }
        let w = contentWidth
        ts.beginEditing()
        ts.enumerateAttribute(.hnTable, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            if let b = v as? TableBox { ts.addAttribute(.attachment, value: NSTextAttachment(image: TableRenderer.image(b, width: w)), range: r) }
        }
        ts.enumerateAttribute(.hnAttachment, in: NSRange(location: 0, length: ts.length)) { v, r, _ in
            guard let ref = v as? AttachmentRef else { return }
            if ref.isImage, let img = images[ref.path] { ts.addAttribute(.attachment, value: AttachmentViews.imageAttachment(img, width: w), range: r) }
            else { ts.addAttribute(.attachment, value: AttachmentViews.placeholder(ref, width: w), range: r) }
        }
        ts.endEditing()
    }

    func openAttachment(_ ref: AttachmentRef) {
        guard let store else { return }
        let id = store.resolve(noteId)
        Task {
            if let url = try? await store.attachmentFile(note: id, path: ref.path) {
                // Quick Look braucht eine Dateiendung
                let named = FileManager.default.temporaryDirectory.appendingPathComponent(
                    ref.decodedPath.split(separator: "/").last.map(String.init) ?? url.lastPathComponent)
                try? FileManager.default.removeItem(at: named)
                try? FileManager.default.copyItem(at: url, to: named)
                previewURL = named
            }
        }
    }

    func deleteAttachment(_ tap: AttachmentTap) {
        guard let store else { return }
        perform {
            if let r = currentRange(of: tap.ref) {
                var del = r
                if NSMaxRange(r) < ts.length, ns.character(at: NSMaxRange(r)) == 10, info(paragraph(at: r.location)).content.length == 1 { del.length += 1 }
                ts.replaceCharacters(in: del, with: "")
                normalize(NSRange(location: r.location, length: 0))
            }
        }
        flush()
        Task { await store.deleteAttachment(note: store.resolve(noteId), path: tap.ref.path) }
    }

    private func currentRange(of ref: AttachmentRef) -> NSRange? {
        var out: NSRange?
        ts.enumerateAttribute(.hnAttachment, in: NSRange(location: 0, length: ts.length)) { v, r, stop in
            if (v as? AttachmentRef) == ref { out = r; stop.pointee = true }
        }
        return out
    }

    // MARK: Links

    func beginLinkEdit() {
        guard !readonly else { return }
        var sel = textView.selectedRange
        var url = ""
        if sel.location < ts.length, let l = ts.attribute(.hnLink, at: sel.location, longestEffectiveRange: &sel, in: NSRange(location: 0, length: ts.length)) as? String {
            url = l
        } else { sel = textView.selectedRange }
        linkEdit = LinkEdit(url: url, text: ns.substring(with: sel), range: sel)
    }

    func applyLink(_ e: LinkEdit, remove: Bool = false) {
        var url = e.url.trimmingCharacters(in: .whitespaces)
        if !remove, !url.isEmpty, !url.contains(":") { url = "https://" + url }
        perform {
            var r = e.range
            let text = e.text.isEmpty ? url : e.text
            if ns.substring(with: r) != text, !remove {
                let a = Styler.semantic(textView.typingAttributes)
                ts.replaceCharacters(in: r, with: NSAttributedString(string: text, attributes: Styler.visual(a)))
                r.length = (text as NSString).length
            }
            ts.removeAttribute(.hnAutolink, range: r)
            if remove || url.isEmpty { ts.removeAttribute(.hnLink, range: r) } else { ts.addAttribute(.hnLink, value: url, range: r) }
            normalize(r)
            textView.selectedRange = NSRange(location: NSMaxRange(r), length: 0)
        }
    }

    // MARK: Einsetzen

    /// Text aus der Zwischenablage als Markdown einsetzen (fremde Schriften/Farben fallen weg).
    func pastePlain() -> Bool {
        guard !readonly, let s = UIPasteboard.general.string, !UIPasteboard.general.hasImages else { return false }
        let paras = MarkdownCodec.parse(s)
        let sel = textView.selectedRange
        perform {
            let insert: NSAttributedString
            if paras.count == 1, paras[0].kind == .body {
                // einzelne Zeile übernimmt das Format der Einfügestelle
                let m = NSMutableAttributedString(attributedString: paras[0].text)
                let base = Styler.semantic(textView.typingAttributes, inline: false)
                m.enumerateAttributes(in: NSRange(location: 0, length: m.length)) { a, r, _ in
                    var sem = base
                    for (k, v) in a { sem[k] = v }
                    m.setAttributes(Styler.visual(sem), range: r)
                }
                insert = m
            } else {
                insert = Styler.attributed(paras, width: contentWidth)
            }
            suppress = true
            ts.replaceCharacters(in: sel, with: insert)
            textView.selectedRange = NSRange(location: sel.location + insert.length, length: 0)
            suppress = false
            normalize(NSRange(location: sel.location, length: insert.length))
            loadAttachments()
        }
        textView.scrollRangeToVisible(textView.selectedRange)
        return true
    }

    // MARK: Formatleiste ein/aus

    func toggleFormatPanel() {
        guard !readonly else { return }
        showFormat.toggle()
        textView.inputView = showFormat ? formatContainer : nil
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
        textView.reloadInputViews()
    }

    func beginEditingAtEnd() {
        guard !readonly else { return }
        if !textView.isFirstResponder {
            textView.selectedRange = NSRange(location: ts.length, length: 0)
            textView.becomeFirstResponder()
        }
    }

    func addChecklist() {
        guard !readonly else { return }
        if !textView.isFirstResponder {
            beginEditingAtEnd()
            let i = info(paragraph(at: ts.length))
            if i.content.length > 0 || i.kind == .table {
                suppress = true; textView.insertText("\n"); suppress = false
                normalize(paragraph(at: ts.length))
            }
        }
        setBlock(.check)
    }

    func dismissKeyboard() { textView.resignFirstResponder() }

    func undo() { textView.undoManager?.undo() }
    func redo() { textView.undoManager?.redo() }

    func findInNote() {
        textView.becomeFirstResponder()
        textView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    var canShowWritingTools: Bool { textView.canPerformAction(#selector(UIResponder.showWritingTools(_:)), withSender: nil) }
    func showWritingTools() { textView.showWritingTools(textView) }

    // MARK: Tippen auf Kreise, Bilder, Tabellen, Links

    private enum Hit { case check(NSRange), attachment(AttachmentRef, NSRange), table(TableBox), link(URL) }

    private func hitTest(_ p: CGPoint) -> Hit? {
        guard ts.length > 0, let pos = textView.closestPosition(to: p) else { return nil }
        let off = textView.offset(from: textView.beginningOfDocument, to: pos)
        for k in [off, off - 1, off + 1] where k >= 0 && k < ts.length {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: k),
                  let end = textView.position(from: start, offset: 1),
                  let tr = textView.textRange(from: start, to: end) else { continue }
            let rect = textView.firstRect(for: tr)
            let a = ts.attributes(at: k, effectiveRange: nil)
            if let m = a[.hnMarker] as? String, m.hasPrefix("check"), ns.character(at: k) == 0xFFFC,
               rect.insetBy(dx: -12, dy: -8).contains(p) { return .check(paragraph(at: k)) }
            if let ref = a[.hnAttachment] as? AttachmentRef, rect.contains(p) { return .attachment(ref, NSRange(location: k, length: 1)) }
            if let t = a[.hnTable] as? TableBox, rect.contains(p) { return .table(t) }
        }
        if !textView.isFirstResponder, off < ts.length, let l = ts.attribute(.hnLink, at: off, effectiveRange: nil) as? String,
           let url = URL(string: l), url.scheme != nil { return .link(url) }
        return nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let hit = hitTest(touch.location(in: textView))
        touchOnSpecial = hit != nil
        if hit != nil, textView.isFirstResponder { specialTouchAt = Date() }
        return hit != nil
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let hit = hitTest(g.location(in: textView)) else { return }
        switch hit {
        case .check(let pr): if !readonly { toggleChecked(pr) }
        case .attachment(let ref, let r): attachmentTap = AttachmentTap(ref: ref, range: r)
        case .table(let t): if readonly { break }; editTable(t)
        case .link(let url): UIApplication.shared.open(url)
        }
    }

    // MARK: Bearbeiten-Menü

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard !readonly, range.length > 0 else { return UIMenu(children: suggestedActions) }
        let format = UIMenu(title: String(localized: "Format"), image: UIImage(systemName: "textformat"), children: [
            UIAction(title: String(localized: "Fett"), image: UIImage(systemName: "bold")) { [weak self] _ in self?.toggleInline(.hnBold) },
            UIAction(title: String(localized: "Kursiv"), image: UIImage(systemName: "italic")) { [weak self] _ in self?.toggleInline(.hnItalic) },
            UIAction(title: String(localized: "Unterstrichen"), image: UIImage(systemName: "underline")) { [weak self] _ in self?.toggleInline(.hnUnderline) },
            UIAction(title: String(localized: "Durchgestrichen"), image: UIImage(systemName: "strikethrough")) { [weak self] _ in self?.toggleInline(.hnStrike) },
        ])
        let link = UIAction(title: String(localized: "Link hinzufügen …"), image: UIImage(systemName: "link")) { [weak self] _ in self?.beginLinkEdit() }
        return UIMenu(children: suggestedActions + [format, link])
    }
}

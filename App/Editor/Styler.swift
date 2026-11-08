import UIKit

/// Wandelt Absätze in formatierten Text für den Editor um (und zurück). Im Text stehen immer beide Ebenen:
/// Bedeutung (`hn…`-Attribute, daraus entsteht Markdown) und Darstellung (Schrift, Einzug, Kreise, Bilder).
@MainActor
enum Styler {
    static let indentStep: CGFloat = 26
    static let accent = UIColor(named: "AccentColor") ?? .systemYellow

    static func markerWidth(_ kind: BlockKind) -> CGFloat {
        switch kind { case .number: 30; case .quote: 16; case .check: 30; default: 22 }
    }

    // MARK: Schriften

    static func baseFont(_ kind: BlockKind, level: Int = 0) -> UIFont {
        switch kind {
        case .title: UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: 28, weight: .bold))
        case .heading: UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .bold))
        case .subheading: UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: level > 3 ? 17 : 19, weight: .semibold))
        case .mono: UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        default: UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17))
        }
    }

    static func font(_ kind: BlockKind, level: Int, bold: Bool, italic: Bool, code: Bool) -> UIFont {
        var f = baseFont(kind, level: level)
        if code && kind != .mono { f = UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular)) }
        var traits = f.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if let d = f.fontDescriptor.withSymbolicTraits(traits) { f = UIFont(descriptor: d, size: f.pointSize) }
        return f
    }

    static func paragraphStyle(_ kind: BlockKind, indent: Int) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let base = CGFloat(indent) * indentStep
        p.firstLineHeadIndent = base
        p.headIndent = kind.hasMarker ? base + markerWidth(kind) : base
        p.tabStops = [NSTextTab(textAlignment: .natural, location: p.headIndent)]
        p.defaultTabInterval = 28
        p.lineHeightMultiple = kind == .body || kind.isList ? 1.04 : 1
        switch kind {
        case .title: p.paragraphSpacing = 4
        case .heading, .subheading: p.paragraphSpacingBefore = 2; p.paragraphSpacing = 2
        case .table: p.paragraphSpacing = 6; p.paragraphSpacingBefore = 6
        default: p.paragraphSpacing = 1
        }
        return p
    }

    /// Bedeutungs-Attribute eines Absatzes.
    static func paragraphKeys(_ kind: BlockKind, indent: Int, checked: Bool, level: Int, fence: String?) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.hnBlock: kind.rawValue, .hnIndent: indent]
        if kind == .check { a[.hnChecked] = checked }
        if kind == .subheading, level > 3 { a[.hnLevel] = level }
        if kind == .mono, let fence { a[.hnFence] = fence }
        return a
    }

    static let paragraphKeyList: [NSAttributedString.Key] = [.hnBlock, .hnIndent, .hnChecked, .hnLevel, .hnFence]

    /// Darstellung für Inhaltszeichen aus Absatz- und Inline-Bedeutung.
    static func visual(_ semantic: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        let kind = BlockKind(rawValue: semantic[.hnBlock] as? String ?? "") ?? .body
        let indent = semantic[.hnIndent] as? Int ?? 0
        let level = semantic[.hnLevel] as? Int ?? 0
        var a = semantic
        a[.font] = font(kind, level: level, bold: semantic[.hnBold] != nil, italic: semantic[.hnItalic] != nil, code: semantic[.hnCode] != nil)
        a[.paragraphStyle] = paragraphStyle(kind, indent: indent)
        a[.foregroundColor] = kind == .quote ? UIColor.secondaryLabel : UIColor.label
        if semantic[.hnUnderline] != nil { a[.underlineStyle] = NSUnderlineStyle.single.rawValue } else { a[.underlineStyle] = nil }
        if semantic[.hnStrike] != nil { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue } else { a[.strikethroughStyle] = nil }
        if semantic[.hnCode] != nil || kind == .mono { a[.backgroundColor] = UIColor.tertiarySystemFill } else { a[.backgroundColor] = nil }
        if let l = semantic[.hnLink] as? String { a[.link] = URL(string: l) ?? l } else { a[.link] = nil }
        return a
    }

    /// Nur Bedeutung behalten (für Tipp-Attribute und Markdown).
    static func semantic(_ a: [NSAttributedString.Key: Any], inline: Bool = true) -> [NSAttributedString.Key: Any] {
        var out: [NSAttributedString.Key: Any] = [:]
        for k in paragraphKeyList { if let v = a[k] { out[k] = v } }
        if inline { for k in Inline.semanticKeys { if let v = a[k] { out[k] = v } } }
        return out
    }

    // MARK: Aufzählungszeichen

    /// Kennung des Zeichens – ändert sie sich (Nummer, Haken), wird es neu gesetzt.
    static func markerId(_ kind: BlockKind, number: Int, checked: Bool) -> String {
        switch kind {
        case .check: checked ? "check1" : "check0"
        case .number: "num\(number)"
        default: kind.rawValue
        }
    }

    static func marker(_ kind: BlockKind, indent: Int, checked: Bool, number: Int, paragraph: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var a = visual(paragraph)
        for k in Inline.semanticKeys { a[k] = nil }
        a[.link] = nil; a[.underlineStyle] = nil; a[.strikethroughStyle] = nil; a[.backgroundColor] = nil
        a[.hnMarker] = markerId(kind, number: number, checked: checked)
        let body = baseFont(.body)
        a[.font] = body
        switch kind {
        case .bullet: return NSAttributedString(string: "•\t", attributes: a)
        case .dash: return NSAttributedString(string: "–\t", attributes: a)
        case .number:
            a[.font] = UIFont.monospacedDigitSystemFont(ofSize: body.pointSize, weight: .regular)
            return NSAttributedString(string: "\(number).\t", attributes: a)
        case .check:
            let s = NSMutableAttributedString(attachment: checkAttachment(checked, font: body))
            s.addAttributes(a, range: NSRange(location: 0, length: s.length))
            s.append(NSAttributedString(string: "\t", attributes: a))
            return s
        case .quote:
            let s = NSMutableAttributedString(attachment: quoteBar(font: body))
            s.addAttributes(a, range: NSRange(location: 0, length: s.length))
            s.append(NSAttributedString(string: "\t", attributes: a))
            return s
        default: return NSAttributedString()
        }
    }

    static func checkAttachment(_ checked: Bool, font: UIFont) -> NSTextAttachment {
        let size = round(font.pointSize * 1.3)
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: checked ? .regular : .light)
        let img = UIImage(systemName: checked ? "checkmark.circle.fill" : "circle", withConfiguration: cfg)?
            .withTintColor(checked ? accent : .tertiaryLabel, renderingMode: .alwaysOriginal)
        let att = NSTextAttachment(image: img ?? UIImage())
        att.bounds = CGRect(x: 0, y: (font.capHeight - size) / 2 - 1, width: size, height: size)
        return att
    }

    static func quoteBar(font: UIFont) -> NSTextAttachment {
        let h = ceil(font.lineHeight)
        let r = UIGraphicsImageRenderer(size: CGSize(width: 4, height: h))
        let img = r.image { _ in
            UIColor.systemGray3.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 3, height: h), cornerRadius: 1.5).fill()
        }
        let att = NSTextAttachment(image: img)
        att.bounds = CGRect(x: 0, y: font.descender, width: 4, height: h)
        return att
    }

    // MARK: Ganze Notiz

    static func attributed(_ paragraphs: [Paragraph], width: CGFloat) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var numbers: [Int: Int] = [:]
        for (i, p) in paragraphs.enumerated() {
            let keys = paragraphKeys(p.kind, indent: p.indent, checked: p.checked, level: p.level, fence: p.fence)
            if p.kind != .number { numbers = numbers.filter { $0.key < p.indent } }
            if p.kind.hasMarker {
                var n = 0
                if p.kind == .number {
                    numbers = numbers.filter { $0.key <= p.indent }
                    n = (numbers[p.indent] ?? 0) + 1
                    numbers[p.indent] = n
                }
                out.append(marker(p.kind, indent: p.indent, checked: p.checked, number: n, paragraph: keys))
            }
            if p.kind == .table, let t = p.table {
                var a = visual(keys)
                a[.hnTable] = t
                let att = NSTextAttachment(image: TableRenderer.image(t, width: width))
                let s = NSMutableAttributedString(attachment: att)
                s.addAttributes(a, range: NSRange(location: 0, length: s.length))
                out.append(s)
            } else {
                let content = NSMutableAttributedString(attributedString: p.text)
                let full = NSRange(location: 0, length: content.length)
                content.enumerateAttributes(in: full) { attrs, r, _ in
                    var sem = keys
                    for (k, v) in attrs { sem[k] = v }
                    var vis = visual(sem)
                    if let ref = attrs[.hnAttachment] as? AttachmentRef {
                        vis[.attachment] = AttachmentViews.placeholder(ref, width: width)
                    }
                    content.setAttributes(vis, range: r)
                }
                out.append(content)
            }
            if i < paragraphs.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: visual(keys)))
            }
        }
        return out
    }

    /// Editor-Text → Absätze (Aufzählungszeichen und Darstellung fallen weg).
    static func paragraphs(from text: NSAttributedString) -> [Paragraph] {
        let ns = text.string as NSString
        var out: [Paragraph] = []
        var loc = 0
        while loc < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            let hasNL = ns.character(at: NSMaxRange(pr) - 1) == 10
            let end = NSMaxRange(pr) - (hasNL ? 1 : 0)
            let attrs = text.attributes(at: pr.location, effectiveRange: nil)
            var p = Paragraph()
            p.kind = BlockKind(rawValue: attrs[.hnBlock] as? String ?? "") ?? .body
            p.indent = attrs[.hnIndent] as? Int ?? 0
            p.checked = attrs[.hnChecked] as? Bool ?? false
            p.level = attrs[.hnLevel] as? Int ?? 0
            p.fence = attrs[.hnFence] as? String
            var start = pr.location
            while start < end, text.attribute(.hnMarker, at: start, effectiveRange: nil) != nil { start += 1 }
            let content = NSMutableAttributedString()
            if start < end {
                text.enumerateAttributes(in: NSRange(location: start, length: end - start)) { a, r, _ in
                    if a[.hnMarker] != nil { return }
                    if let t = a[.hnTable] as? TableBox { p.table = t.copy(); return }
                    var sem: [NSAttributedString.Key: Any] = [:]
                    for k in Inline.semanticKeys { if let v = a[k] { sem[k] = v } }
                    var s = ns.substring(with: r)
                    if a[.hnAttachment] == nil { s = s.replacingOccurrences(of: "\u{FFFC}", with: "") }
                    content.append(NSAttributedString(string: s, attributes: sem))
                }
            }
            if p.kind == .table, p.table == nil { p.kind = .body }
            p.text = content
            out.append(p)
            loc = NSMaxRange(pr)
        }
        if ns.length > 0, ns.character(at: ns.length - 1) == 10 {
            // endet mit Zeilenumbruch → leerer letzter Absatz
            out.append(Paragraph())
        }
        if out.isEmpty { out = [Paragraph()] }
        return out
    }
}

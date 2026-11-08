import UIKit
import ImageIO

/// Tabellen werden im Editor als Bild gezeigt (Tippen öffnet den Tabellen-Editor) – in Markdown bleiben sie GFM-Tabellen.
@MainActor
enum TableRenderer {
    static let pad: CGFloat = 8

    static func image(_ t: TableBox, width: CGFloat) -> UIImage {
        t.normalize()
        let maxW = max(width, 120)
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 15))
        let cells: [[NSAttributedString]] = t.rows.map { row in row.map { cellText($0, font: font) } }
        let cols = t.columns
        // natürliche Breiten, dann auf die verfügbare Breite verteilen
        var natural = [CGFloat](repeating: 40, count: cols)
        for row in cells { for (c, s) in row.enumerated() { natural[c] = max(natural[c], ceil(s.size().width) + 2 * pad) } }
        var widths = natural
        let total = natural.reduce(0, +)
        if total > maxW {
            let minW: CGFloat = 60
            widths = natural.map { max(minW, $0 * maxW / total) }
            let sum = widths.reduce(0, +)
            if sum > maxW { widths = widths.map { $0 * maxW / sum } }
        }
        let tableW = min(maxW, widths.reduce(0, +))
        var heights: [CGFloat] = []
        for row in cells {
            var h: CGFloat = font.lineHeight + 2 * pad
            for (c, s) in row.enumerated() {
                let r = s.boundingRect(with: CGSize(width: widths[c] - 2 * pad, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
                h = max(h, ceil(r.height) + 2 * pad)
            }
            heights.append(h)
        }
        let size = CGSize(width: ceil(tableW) + 1, height: ceil(heights.reduce(0, +)) + 1)
        let r = UIGraphicsImageRenderer(size: size)
        return r.image { ctx in
            let g = ctx.cgContext
            let outer = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), cornerRadius: 8)
            outer.addClip()
            UIColor.secondarySystemBackground.withAlphaComponent(0.35).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            var y: CGFloat = 0
            for (ri, row) in cells.enumerated() {
                var x: CGFloat = 0
                for (c, s) in row.enumerated() {
                    s.draw(with: CGRect(x: x + pad, y: y + pad, width: widths[c] - 2 * pad, height: heights[ri] - 2 * pad),
                           options: [.usesLineFragmentOrigin], context: nil)
                    x += widths[c]
                }
                y += heights[ri]
            }
            UIColor.separator.setStroke()
            g.setLineWidth(1)
            y = 0
            for h in heights.dropLast() { y += h; g.move(to: CGPoint(x: 0, y: y + 0.5)); g.addLine(to: CGPoint(x: size.width, y: y + 0.5)) }
            var x: CGFloat = 0
            for w in widths.dropLast() { x += w; g.move(to: CGPoint(x: x + 0.5, y: 0)); g.addLine(to: CGPoint(x: x + 0.5, y: size.height)) }
            g.strokePath()
            UIColor.separator.setStroke()
            outer.lineWidth = 1
            outer.stroke()
        }
    }

    static func cellText(_ md: String, font: UIFont) -> NSAttributedString {
        let p = Inline.parse(md.replacingOccurrences(of: "<br>", with: "\n"))
        let m = NSMutableAttributedString(attributedString: p)
        m.enumerateAttributes(in: NSRange(location: 0, length: m.length)) { a, r, _ in
            var f = font
            var tr = f.fontDescriptor.symbolicTraits
            if a[.hnBold] != nil { tr.insert(.traitBold) }
            if a[.hnItalic] != nil { tr.insert(.traitItalic) }
            if let d = f.fontDescriptor.withSymbolicTraits(tr) { f = UIFont(descriptor: d, size: f.pointSize) }
            var v: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: a[.hnLink] != nil ? Styler.accent : UIColor.label]
            if a[.hnStrike] != nil { v[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if a[.hnUnderline] != nil { v[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            m.setAttributes(v, range: r)
        }
        return m
    }
}

/// Bilder und Dateien im Editor.
@MainActor
enum AttachmentViews {
    static func placeholder(_ ref: AttachmentRef, width: CGFloat) -> NSTextAttachment {
        if ref.isImage {
            let w = max(min(width, 320), 120)
            let size = CGSize(width: w, height: w * 0.6)
            let img = UIGraphicsImageRenderer(size: size).image { _ in
                UIColor.secondarySystemFill.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10).fill()
                if let sym = UIImage(systemName: "photo", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30))?
                    .withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal) {
                    sym.draw(at: CGPoint(x: (size.width - sym.size.width) / 2, y: (size.height - sym.size.height) / 2))
                }
            }
            let att = NSTextAttachment(image: img)
            att.bounds = CGRect(origin: .zero, size: size)
            return att
        }
        let img = fileCard(name: ref.name.isEmpty ? (ref.decodedPath.split(separator: "/").last.map(String.init) ?? "") : ref.name,
                           path: ref.decodedPath, width: width)
        let att = NSTextAttachment(image: img)
        att.bounds = CGRect(origin: CGPoint(x: 0, y: -8), size: img.size)
        return att
    }

    /// Fertiges Bild in die Breite einpassen, Ecken abrunden.
    static func imageAttachment(_ image: UIImage, width: CGFloat) -> NSTextAttachment {
        let maxW = max(width, 80)
        let scale = min(1, maxW / max(image.size.width, 1))
        let size = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 10).addClip()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        let att = NSTextAttachment(image: img)
        att.bounds = CGRect(origin: .zero, size: size)
        return att
    }

    static func fileCard(name: String, path: String, width: CGFloat) -> UIImage {
        let w = min(max(width, 200), 360)
        let size = CGSize(width: w, height: 56)
        let ext = (path.split(separator: ".").last.map(String.init) ?? "").lowercased()
        let symbol: String
        switch ext {
        case "pdf": symbol = "doc.richtext"
        case "mov", "mp4", "m4v": symbol = "film"
        case "m4a", "mp3", "wav", "aac": symbol = "waveform"
        case "zip": symbol = "doc.zipper"
        default: symbol = "doc"
        }
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.secondarySystemFill.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 12).fill()
            if let sym = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22))?
                .withTintColor(Styler.accent, renderingMode: .alwaysOriginal) {
                sym.draw(at: CGPoint(x: 14, y: (size.height - sym.size.height) / 2))
            }
            let title = NSAttributedString(string: name, attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: UIColor.label])
            let sub = NSAttributedString(string: ext.uppercased(), attributes: [
                .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.secondaryLabel])
            title.draw(with: CGRect(x: 50, y: 10, width: w - 62, height: 20), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            sub.draw(with: CGRect(x: 50, y: 31, width: w - 62, height: 16), options: [.usesLineFragmentOrigin], context: nil)
        }
    }

    /// Verkleinert laden (große Fotos würden sonst viel Speicher brauchen).
    nonisolated static func downsample(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg, scale: 2, orientation: .up)
    }
}

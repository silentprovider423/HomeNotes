// Erzeugt das App-Symbol von HomeNotes (Notizblatt mit Haus auf Bernstein-Verlauf), 1024 × 1024:
//   swift tools/make-icon.swift Resources/Assets.xcassets
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
    }
    // Hintergrund (iOS rundet die Ecken selbst ab)
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(0xFFD95A), rgb(0xF0A202)] as CFArray, locations: [0, 1])!
    ctx.setFillColor(rgb(0xF6BD2A)); ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    ctx.drawLinearGradient(bg, start: CGPoint(x: 300, y: 1024), end: CGPoint(x: 724, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Blatt mit Schatten, leicht gedreht
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 500)
    ctx.rotate(by: -0.06)
    let sheet = CGRect(x: -270, y: -330, width: 540, height: 660)
    let sheetPath = CGPath(roundedRect: sheet, cornerWidth: 58, cornerHeight: 58, transform: nil)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: rgb(0x7A4A00, 0.35))
    ctx.addPath(sheetPath); ctx.setFillColor(rgb(0xFFFDF6)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Kopfleiste
    ctx.saveGState()
    ctx.addPath(sheetPath); ctx.clip()
    ctx.setFillColor(rgb(0xFFE7A1))
    ctx.fill(CGRect(x: -270, y: 190, width: 540, height: 140))
    ctx.restoreGState()
    // Haus in der Kopfleiste
    let house = CGMutablePath()
    house.move(to: CGPoint(x: -205, y: 232)); house.addLine(to: CGPoint(x: -205, y: 268))
    house.addLine(to: CGPoint(x: -168, y: 300)); house.addLine(to: CGPoint(x: -131, y: 268))
    house.addLine(to: CGPoint(x: -131, y: 232)); house.closeSubpath()
    ctx.addPath(house); ctx.setFillColor(rgb(0xE08E00)); ctx.fillPath()
    ctx.setFillColor(rgb(0xFFE7A1)); ctx.fill(CGRect(x: -176, y: 232, width: 16, height: 26))
    // Titelzeile + Textzeilen
    ctx.setFillColor(rgb(0x3A3326))
    ctx.addPath(CGPath(roundedRect: CGRect(x: -105, y: 246, width: 250, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil)); ctx.fillPath()
    let lines: [(CGFloat, CGFloat)] = [(110, 400), (40, 360), (-30, 410), (-100, 300)]
    for (y, w) in lines {
        ctx.setFillColor(rgb(0xC9BFA8))
        ctx.addPath(CGPath(roundedRect: CGRect(x: -205, y: y, width: w, height: 24), cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
    }
    // Checkliste unten: Kreis mit Haken
    ctx.setStrokeColor(rgb(0xE08E00)); ctx.setLineWidth(14)
    ctx.addEllipse(in: CGRect(x: -205, y: -240, width: 64, height: 64)); ctx.setFillColor(rgb(0xF0A202)); ctx.fillPath()
    ctx.setStrokeColor(rgb(0xFFFFFF)); ctx.setLineWidth(11); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: -189, y: -208)); ctx.addLine(to: CGPoint(x: -177, y: -221)); ctx.addLine(to: CGPoint(x: -156, y: -195)); ctx.strokePath()
    ctx.setFillColor(rgb(0xC9BFA8))
    ctx.addPath(CGPath(roundedRect: CGRect(x: -115, y: -220, width: 260, height: 24), cornerWidth: 12, cornerHeight: 12, transform: nil)); ctx.fillPath()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let png = render(1024).representation(using: .png, properties: [:])!
try! png.write(to: out.appendingPathComponent("AppIcon.appiconset/AppIcon.png"))
try! png.write(to: out.appendingPathComponent("LoginIcon.imageset/LoginIcon.png"))
print("Symbol geschrieben nach \(out.path)")

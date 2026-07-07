// Generates the DMG background: a fake Quick Look window "previewing" a
// .gslides file, with the drag-to-install row inside it — the installer
// demos the product. Native CoreGraphics/AppKit, no deps.
// Run: swift dmg/make-bg.swift
// Emits dmg/assets/dmg-bg.png (@1x) and dmg/assets/dmg-bg@2x.png (retina).
import AppKit


let UI: CGFloat = 1.5   // window scale: logical 660x420 art rendered UIx bigger
let W: CGFloat = 660, H: CGFloat = 420
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}
let gold = (r: CGFloat(0.722), g: CGFloat(0.580), b: CGFloat(0.373))

// Window geometry (icon positions must land inside content area)
let win = CGRect(x: 22, y: 20, width: W - 44, height: H - 40)   // CG bottom-origin
let titleH: CGFloat = 36
let iconY: CGFloat = 265   // create-dmg y (from top)

func drawText(_ ctx: CGContext, _ s: NSAttributedString, x: CGFloat, y: CGFloat) {
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    s.draw(at: NSPoint(x: x, y: y))
    NSGraphicsContext.restoreGraphicsState()
}
func attr(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color, .kern: kern])
}

// Crop a CGImage to its non-transparent pixel bounds.
func trimToAlpha(_ img: CGImage) -> CGImage? {
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: w * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return nil }
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h { for x in 0..<w {
        if px[(y * w + x) * 4 + 3] > 8 {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }}
    guard maxX >= minX, maxY >= minY else { return nil }
    return img.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
}

func render(scale: CGFloat, to path: String) {
    guard let ctx = CGContext(data: nil, width: Int(W*UI*scale), height: Int(H*UI*scale),
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.scaleBy(x: UI*scale, y: UI*scale)

    // Desktop backdrop behind the fake window: very dark neutral
    ctx.setFillColor(c(0.075, 0.08, 0.078, 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    // Window with shadow
    let winPath = CGPath(roundedRect: win, cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 28, color: c(0, 0, 0, 0.55))
    ctx.addPath(winPath)
    ctx.setFillColor(c(0.10, 0.13, 0.125, 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to window; content gradient (brand teal)
    ctx.saveGState()
    ctx.addPath(winPath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: space, colors: [
        c(0.150, 0.200, 0.190, 1), c(0.045, 0.062, 0.058, 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad,
        start: CGPoint(x: 0, y: win.maxY - titleH), end: CGPoint(x: 0, y: win.minY), options: [])

    // Title bar: darker strip + hairline
    let barRect = CGRect(x: win.minX, y: win.maxY - titleH, width: win.width, height: titleH)
    ctx.setFillColor(c(0.11, 0.115, 0.112, 1))
    ctx.fill(barRect)
    ctx.setFillColor(c(1, 1, 1, 0.08))
    ctx.fill(CGRect(x: win.minX, y: win.maxY - titleH, width: win.width, height: 1))

    // QL-style gray buttons (close, no-entry)
    for (i, sym) in ["xmark", "slash.circle"].enumerated() {
        let cxx = win.minX + 22 + CGFloat(i) * 24
        let cyy = barRect.midY
        ctx.setFillColor(c(0.35, 0.36, 0.355, 1))
        ctx.fillEllipse(in: CGRect(x: cxx - 7, y: cyy - 7, width: 14, height: 14))
        if sym == "xmark" {
            ctx.setStrokeColor(c(0.08, 0.08, 0.08, 1)); ctx.setLineWidth(1.6); ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cxx - 3, y: cyy - 3)); ctx.addLine(to: CGPoint(x: cxx + 3, y: cyy + 3))
            ctx.move(to: CGPoint(x: cxx - 3, y: cyy + 3)); ctx.addLine(to: CGPoint(x: cxx + 3, y: cyy - 3))
            ctx.strokePath()
        } else {
            ctx.setStrokeColor(c(0.08, 0.08, 0.08, 1)); ctx.setLineWidth(1.4)
            ctx.strokeEllipse(in: CGRect(x: cxx - 4, y: cyy - 4, width: 8, height: 8))
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cxx - 2.8, y: cyy + 2.8)); ctx.addLine(to: CGPoint(x: cxx + 2.8, y: cyy - 2.8))
            ctx.strokePath()
        }
    }
    // Window title
    let title = attr("Spyglass.gslides", 13, .semibold, NSColor(white: 1, alpha: 0.92))
    drawText(ctx, title, x: win.minX + 60, y: barRect.midY - title.size().height/2 + 1)

    // Pill button top-right: "Open with Spyglass" — golden, the QL 'open with' parody
    let pillText = attr("Open with Spyglass", 12.5, .semibold, NSColor(white: 0.07, alpha: 1))
    let tw = pillText.size().width
    let pill = CGRect(x: win.maxX - tw - 44, y: barRect.midY - 12, width: tw + 28, height: 24)
    ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.setFillColor(c(gold.r, gold.g, gold.b, 1))
    ctx.fillPath()
    drawText(ctx, pillText, x: pill.minX + 14, y: pill.midY - pillText.size().height/2 + 0.5)

    // Hero inside content: slide-style headline, keyword in gold
    let hero = NSMutableAttributedString()
    hero.append(attr("Real ", 27, .bold, .white))
    hero.append(attr("Quick Look", 27, .bold, NSColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1)))
    hero.append(attr(" Previews", 27, .bold, .white))
    drawText(ctx, hero, x: (W - hero.size().width)/2, y: H - 130)

    // SF Symbol arrow between icons.
    // cx is 5px left of geometric center: folder artwork fills its box wider
    // than the app icon, so the optical midpoint of the visible gap sits left.
    let ay = H - iconY, cx: CGFloat = 325
    if let sym = NSImage(systemSymbolName: "arrowshape.right.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 46, weight: .regular)) {
        let tinted = NSImage(size: sym.size, flipped: false) { rect in
            sym.draw(in: rect)
            NSColor(red: gold.r, green: gold.g, blue: gold.b, alpha: 1).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        if let cg = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let trimmed = trimToAlpha(cg) {   // strip symbol padding so glyph centers optically
            let sh: CGFloat = 38
            let sw = sh * CGFloat(trimmed.width) / CGFloat(trimmed.height)
            ctx.saveGState()
            ctx.setAlpha(0.65)
            ctx.draw(trimmed, in: CGRect(x: cx - sw/2, y: ay - sh/2, width: sw, height: sh))
            ctx.restoreGState()
        }
    }

    ctx.restoreGState()   // un-clip window

    guard let img = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}


let dir = (CommandLine.arguments.first as NSString?)?.deletingLastPathComponent ?? "."
render(scale: 1, to: "\(dir)/assets/dmg-bg.png")
render(scale: 2, to: "\(dir)/assets/dmg-bg@2x.png")

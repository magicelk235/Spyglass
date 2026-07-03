// Generates the DMG background: navy gradient + mountain motif + drag hint.
// Native CoreGraphics, no deps. Run: swift dmg/make-bg.swift
// Emits dmg/assets/dmg-bg.png (@1x) and dmg/assets/dmg-bg@2x.png (retina).
import AppKit

// Logical window size (must match create-dmg --window-size). @2x for retina.
let W: CGFloat = 660, H: CGFloat = 420

func render(scale: CGFloat, to path: String) {
    let pxW = Int(W * scale), pxH = Int(H * scale)
    guard let ctx = CGContext(
        data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.scaleBy(x: scale, y: scale)

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Vertical navy gradient, matching the app icon (top lighter, bottom near-black).
    let top    = CGColor(colorSpace: space, components: [0.137, 0.165, 0.322, 1])! // #232a52
    let bottom = CGColor(colorSpace: space, components: [0.055, 0.067, 0.145, 1])! // #0e1125
    let grad = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

    // Silver mountain motif, bottom, very low alpha — brand echo, not a distraction.
    func mountain(peakX: CGFloat, peakY: CGFloat, baseHalf: CGFloat, alpha: CGFloat) {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: peakX - baseHalf, y: 0))
        ctx.addLine(to: CGPoint(x: peakX, y: peakY))
        ctx.addLine(to: CGPoint(x: peakX + baseHalf, y: 0))
        ctx.closePath()
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.82, 0.85, 0.92, alpha])!)
        ctx.fillPath()
    }
    mountain(peakX: 300, peakY: 150, baseHalf: 220, alpha: 0.05)
    mountain(peakX: 180, peakY: 105, baseHalf: 150, alpha: 0.06)

    // Chunky filled arrow glyph, centered between icon @150 and Applications @510.
    let arrowY: CGFloat = 210
    let cx: CGFloat = 330               // horizontal center of the glyph
    let shaftH: CGFloat = 14            // shaft thickness
    let shaftLen: CGFloat = 34          // shaft length (short)
    let headW: CGFloat = 26            // arrowhead length
    let headH: CGFloat = 34            // arrowhead half-height * 2
    let x0 = cx - (shaftLen + headW) / 2
    ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 0.34])!)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: x0,                 y: arrowY + shaftH / 2))
    ctx.addLine(to: CGPoint(x: x0 + shaftLen,   y: arrowY + shaftH / 2))
    ctx.addLine(to: CGPoint(x: x0 + shaftLen,   y: arrowY + headH / 2))
    ctx.addLine(to: CGPoint(x: x0 + shaftLen + headW, y: arrowY))     // tip
    ctx.addLine(to: CGPoint(x: x0 + shaftLen,   y: arrowY - headH / 2))
    ctx.addLine(to: CGPoint(x: x0 + shaftLen,   y: arrowY - shaftH / 2))
    ctx.addLine(to: CGPoint(x: x0,              y: arrowY - shaftH / 2))
    ctx.closePath()
    ctx.fillPath()

    // Text via NSAttributedString drawn into the same CG context (flipped).
    func drawText(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, tracking: CGFloat = 0) {
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: 1, alpha: alpha),
            .kern: tracking,
        ]
        NSAttributedString(string: s, attributes: attrs).draw(at: NSPoint(x: x, y: y))
        NSGraphicsContext.restoreGraphicsState()
    }
    // Wordmark top-left. y measured from bottom (CG origin).
    drawText("Spyglass", x: 40, y: H - 62, size: 30, weight: .semibold, alpha: 0.96, tracking: 0.5)
    drawText("Real Quick Look previews for Google Workspace files",
             x: 41, y: H - 88, size: 12.5, weight: .regular, alpha: 0.5)
    // Caption under the arrow.
    drawText("drag to install", x: 288, y: arrowY - 48, size: 11, weight: .medium, alpha: 0.4, tracking: 1.5)

    guard let img = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(pxW)x\(pxH))")
}

let dir = (CommandLine.arguments.first as NSString?)?.deletingLastPathComponent ?? "."
render(scale: 1, to: "\(dir)/assets/dmg-bg.png")
render(scale: 2, to: "\(dir)/assets/dmg-bg@2x.png")

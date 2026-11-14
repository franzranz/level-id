// make_icon.swift – zeichnet das App-Icon „Level iD“ als 1024×1024-PNG (CoreGraphics).
// Motiv: der grosse Drehregler des ID14 (Kreis mit Zeiger) plus Lautstaerkebogen, dunkler Grund.
// Aufruf: make_icon <ausgabe.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

// macOS-Icon-Raster: Inhalt 824×824 mit 100 px Rand, Eckenradius ~185
let inset: CGFloat = 100
let plate = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Schatten unter der Platte
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.45))
ctx.addPath(platePath); ctx.setFillColor(color(0.10, 0.10, 0.11)); ctx.fillPath()
ctx.restoreGState()

// Platte: dunkler Graphit-Verlauf
ctx.saveGState()
ctx.addPath(platePath); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [color(0.20, 0.20, 0.22), color(0.07, 0.07, 0.08)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
ctx.restoreGState()

let c = CGPoint(x: size / 2, y: size / 2)

// Lautstaerkebogen: Spur (dunkel) von 225° bis -45° im Uhrzeigersinn, aktiver Teil (hell) bis ~20°
let arcR: CGFloat = 300, arcW: CGFloat = 38
func arc(from a0: CGFloat, to a1: CGFloat, _ col: CGColor) {
    ctx.setLineCap(.round); ctx.setLineWidth(arcW); ctx.setStrokeColor(col)
    ctx.addArc(center: c, radius: arcR, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: true)
    ctx.strokePath()
}
arc(from: 225, to: -45, color(1, 1, 1, 0.12))
arc(from: 225, to: 20, color(0.96, 0.96, 0.97))

// Drehknopf: Kreis mit dezentem Verlauf und feinem Rand
let knobR: CGFloat = 205
let knobRect = CGRect(x: c.x - knobR, y: c.y - knobR, width: 2 * knobR, height: 2 * knobR)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.55))
ctx.addEllipse(in: knobRect); ctx.setFillColor(color(0.16, 0.16, 0.17)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addEllipse(in: knobRect); ctx.clip()
let kg = CGGradient(colorsSpace: cs, colors: [color(0.30, 0.30, 0.32), color(0.13, 0.13, 0.14)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(kg, start: CGPoint(x: c.x, y: knobRect.maxY), end: CGPoint(x: c.x, y: knobRect.minY), options: [])
ctx.restoreGState()
ctx.setLineWidth(4); ctx.setStrokeColor(color(1, 1, 1, 0.10)); ctx.strokeEllipse(in: knobRect.insetBy(dx: 2, dy: 2))

// Zeigerstrich in Richtung des Bogenendes (20°)
let ang: CGFloat = 20 * .pi / 180
// Zeiger nur noch am Rand des Knopfs (Platz fuer "iD" in der Mitte)
let p0 = CGPoint(x: c.x + cos(ang) * 150, y: c.y + sin(ang) * 150)
let p1 = CGPoint(x: c.x + cos(ang) * 182, y: c.y + sin(ang) * 182)
ctx.setLineCap(.round); ctx.setLineWidth(26); ctx.setStrokeColor(color(0.96, 0.96, 0.97))
ctx.move(to: p0); ctx.addLine(to: p1); ctx.strokePath()

// Schriftzug "iD" mittig auf dem Knopf (schlichte Systemschrift, kein Hersteller-Logo)
let font = NSFont.systemFont(ofSize: 168, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.97, alpha: 1), .kern: -4]
let text = NSAttributedString(string: "iD", attributes: attrs)
let line = CTLineCreateWithAttributedString(text)
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
ctx.textPosition = CGPoint(x: c.x - bounds.midX, y: c.y - bounds.midY)
CTLineDraw(line, ctx)

guard let img = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: img)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try? png.write(to: URL(fileURLWithPath: out))
print("Icon geschrieben: \(out)")

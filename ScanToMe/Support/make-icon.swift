// Erzeugt das App-Symbol „Scan to me“ als PNG (1024×1024).
// Aufruf: swift Support/make-icon.swift <ausgabe.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = URL(fileURLWithPath: CommandLine.arguments[1])

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

// Hintergrund: abgerundetes Quadrat im macOS-Raster (824 px Fläche, 100 px Rand), grün-türkiser Verlauf.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(color(14, 110, 95))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [color(40, 180, 150), color(12, 100, 85)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Blatt mit Eselsohr.
let sheet = CGRect(x: 270, y: 205, width: 400, height: 540)
let fold: CGFloat = 105
let sheetPath = CGMutablePath()
sheetPath.move(to: CGPoint(x: sheet.minX, y: sheet.minY))
sheetPath.addLine(to: CGPoint(x: sheet.maxX, y: sheet.minY))
sheetPath.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
sheetPath.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
sheetPath.addLine(to: CGPoint(x: sheet.minX, y: sheet.maxY))
sheetPath.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0, 0, 0, 0.3))
ctx.addPath(sheetPath)
ctx.setFillColor(color(255, 255, 255))
ctx.fillPath()
ctx.restoreGState()

let foldPath = CGMutablePath()
foldPath.move(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
foldPath.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY - fold))
foldPath.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
foldPath.closeSubpath()
ctx.addPath(foldPath)
ctx.setFillColor(color(205, 230, 224))
ctx.fillPath()

// Textzeilen.
ctx.setFillColor(color(150, 190, 180))
let lines: [(CGFloat, CGFloat)] = [(640, 200), (575, 300), (520, 300), (465, 300), (410, 230), (355, 280)]
for (y, width) in lines {
    let line = CGPath(roundedRect: CGRect(x: sheet.minX + 50, y: y, width: width, height: 26),
                      cornerWidth: 13, cornerHeight: 13, transform: nil)
    ctx.addPath(line)
    ctx.fillPath()
}

// Orangefarbener Kreis mit Pfeil nach unten: „wird bei mir abgelegt“.
let badgeCenter = CGPoint(x: 680, y: 300)
let badgeRadius: CGFloat = 150
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: color(0, 0, 0, 0.35))
ctx.addEllipse(in: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                          width: badgeRadius * 2, height: badgeRadius * 2))
ctx.setFillColor(color(240, 140, 30))
ctx.fillPath()
ctx.restoreGState()
ctx.setStrokeColor(color(255, 255, 255))
ctx.setLineWidth(14)
ctx.addEllipse(in: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                          width: badgeRadius * 2, height: badgeRadius * 2))
ctx.strokePath()

let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: badgeCenter.x - 26, y: badgeCenter.y + 80))
arrow.addLine(to: CGPoint(x: badgeCenter.x + 26, y: badgeCenter.y + 80))
arrow.addLine(to: CGPoint(x: badgeCenter.x + 26, y: badgeCenter.y - 10))
arrow.addLine(to: CGPoint(x: badgeCenter.x + 78, y: badgeCenter.y - 10))
arrow.addLine(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y - 92))
arrow.addLine(to: CGPoint(x: badgeCenter.x - 78, y: badgeCenter.y - 10))
arrow.addLine(to: CGPoint(x: badgeCenter.x - 26, y: badgeCenter.y - 10))
arrow.closeSubpath()
ctx.addPath(arrow)
ctx.setFillColor(color(255, 255, 255))
ctx.fillPath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png, properties: [:])!.write(to: output)
print("Symbol geschrieben: \(output.path)")

// Render PrivacyFlow's app icon as a 1024 x 1024 PNG.
//
//     swift scripts/make-icon.swift <output.png>
//
// The icon is the capsule's own mark: the four bars that show PrivacyFlow
// listening, standing at their resting heights. The mark is what the user sees
// all day, so the icon is recognisably the same thing rather than a separate
// illustration of it.
//
// The body follows Apple's macOS icon grid: an 824-point rounded square with
// continuous corners, centred on the 1024 canvas, with the standard soft shadow
// in the margin. macOS 26 applies its own mask and rim to the same square.
import AppKit

let canvas: CGFloat = 1024
let bodySide: CGFloat = 824
let bodyRadius: CGFloat = 185

// The capsule's mark, in fractions of its box, exactly as CapsuleView draws it:
// each bar's left edge and resting height, and the shared bar width.
let bars: [(x: CGFloat, height: CGFloat)] = [(0.00, 0.27), (0.26, 0.67), (0.52, 0.37), (0.78, 0.57)]
let barWidthFraction: CGFloat = 4 / 36

func rgb(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
}

// A near-black body, and bars in the green the capsule shows while listening.
let bodyTop = rgb(38, 38, 42)
let bodyBottom = rgb(10, 10, 12)
let barTop = rgb(132, 232, 181)
let barBottom = rgb(72, 196, 136)
let rim = rgb(255, 255, 255, 0.10)

/// A rounded rectangle with Apple's continuous corners, the curvature easing
/// into the straight edges instead of meeting them at a circular arc's hard
/// join. The constants are the published fit of the iOS 7 and macOS corner.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    let path = CGMutablePath()

    /// One corner, described along its two edges: `along` points from the
    /// corner back down the edge the path arrives on, `away` down the edge it
    /// leaves by, so the same offsets draw all four corners.
    func corner(_ c: CGPoint, along: CGVector, away: CGVector) {
        func point(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: c.x + along.dx * a * r + away.dx * b * r, y: c.y + along.dy * a * r + away.dy * b * r)
        }
        path.addLine(to: point(1.52866483, 0))
        path.addCurve(to: point(0.66993427, 0.06549600), control1: point(1.08849323, 0), control2: point(0.86840689, 0))
        path.addLine(to: point(0.63149399, 0.07491100))
        path.addCurve(to: point(0.07491100, 0.63149399), control1: point(0.37282392, 0.16215301), control2: point(0.16215301, 0.37282392))
        path.addLine(to: point(0.06549600, 0.66993427))
        path.addCurve(to: point(0, 1.52866483), control1: point(0, 0.86840689), control2: point(0, 1.08849323))
    }

    path.move(to: CGPoint(x: rect.minX + 1.52866483 * r, y: rect.maxY))
    corner(CGPoint(x: rect.maxX, y: rect.maxY), along: CGVector(dx: -1, dy: 0), away: CGVector(dx: 0, dy: -1))
    corner(CGPoint(x: rect.maxX, y: rect.minY), along: CGVector(dx: 0, dy: 1), away: CGVector(dx: -1, dy: 0))
    corner(CGPoint(x: rect.minX, y: rect.minY), along: CGVector(dx: 1, dy: 0), away: CGVector(dx: 0, dy: 1))
    corner(CGPoint(x: rect.minX, y: rect.maxY), along: CGVector(dx: 0, dy: -1), away: CGVector(dx: 1, dy: 0))
    path.closeSubpath()
    return path
}

/// Fill `path` with a vertical gradient from `top` to `bottom` across `rect`.
func fillVertically(_ context: CGContext, _ path: CGPath, _ rect: CGRect, top: CGColor, bottom: CGColor) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [bottom, top] as CFArray, locations: [0, 1])!
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
    context.restoreGState()
}

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // The body, lifted off the desktop by Apple's template shadow...
    let body = CGRect(x: (canvas - bodySide) / 2, y: (canvas - bodySide) / 2, width: bodySide, height: bodySide)
    let bodyPath = continuousRoundedRect(body, radius: bodyRadius)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: NSColor(white: 0, alpha: 0.30).cgColor)
    context.addPath(bodyPath)
    context.setFillColor(bodyBottom)
    context.fillPath()
    context.restoreGState()
    fillVertically(context, bodyPath, body, top: bodyTop, bottom: bodyBottom)

    // ...with a hairline rim so a dark icon still has an edge on a dark Dock.
    context.saveGState()
    context.addPath(continuousRoundedRect(body.insetBy(dx: 1, dy: 1), radius: bodyRadius - 1))
    context.setStrokeColor(rim)
    context.setLineWidth(2)
    context.strokePath()
    context.restoreGState()

    // The mark, centred optically: its box is square, and wide enough that the
    // bars read at 16 points.
    let box = CGFloat(470)
    let barWidth = box * barWidthFraction * 1.35
    let span = box * bars.last!.x + barWidth
    let origin = CGPoint(x: (canvas - span) / 2, y: canvas / 2)
    for bar in bars {
        let height = box * bar.height
        let rect = CGRect(x: origin.x + box * bar.x, y: origin.y - height / 2, width: barWidth, height: height)
        let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        fillVertically(context, path, rect, top: barTop, bottom: barBottom)
    }
    return rep
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.png>\n".utf8))
    exit(2)
}
let png = render().representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: arguments[1]))

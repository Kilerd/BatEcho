// Masks square artwork into the macOS app icon shape: an 824 px continuous-corner
// square centred on a 1024 px canvas, with a soft drop shadow, as in Apple's template.
import CoreGraphics
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("usage: make-icon-master.swift input.png output.png\n".utf8))
    exit(1)
}

let canvas = 1024, side: CGFloat = 824, radius: CGFloat = 185.4
let body = CGRect(x: (CGFloat(canvas) - side) / 2, y: (CGFloat(canvas) - side) / 2, width: side, height: side)

/// Continuous ("squircle") corners, matching UIBezierPath's rounded rect since iOS 7.
func continuousRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
    let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                   CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    let path = CGMutablePath()
    for (index, corner) in corners.enumerated() {
        // a runs back along the incoming edge, b along the outgoing edge, both in units of r.
        let previous = corners[(index + 3) % 4], next = corners[(index + 1) % 4]
        let back = CGPoint(x: (previous.x - corner.x) / rect.width, y: (previous.y - corner.y) / rect.height)
        let forward = CGPoint(x: (next.x - corner.x) / rect.width, y: (next.y - corner.y) / rect.height)
        func point(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: corner.x + (back.x * a + forward.x * b) * r, y: corner.y + (back.y * a + forward.y * b) * r)
        }
        if index == 0 { path.move(to: point(1.52866483, 0)) } else { path.addLine(to: point(1.52866483, 0)) }
        path.addCurve(to: point(0.63149399, 0.07491100), control1: point(1.08849296, 0), control2: point(0.86840694, 0))
        path.addCurve(to: point(0.07491100, 0.63149399), control1: point(0.37282392, 0.16905899),
                      control2: point(0.16905899, 0.37282392))
        path.addCurve(to: point(0, 1.52866483), control1: point(0, 0.86840694), control2: point(0, 1.08849296))
    }
    path.closeSubpath()
    return path
}

guard let context = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
context.interpolationQuality = .high
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
context.beginTransparencyLayer(auxiliaryInfo: nil)
context.addPath(continuousRoundedRect(body, radius: radius))
context.clip()
context.draw(artwork, in: body)
context.endTransparencyLayer()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL,
                                                        "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }

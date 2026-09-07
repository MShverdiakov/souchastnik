import AppKit
import ImageIO
import UniformTypeIdentifiers
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSColor(srgbRed: 0.25, green: 0.23, blue: 0.69, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
NSColor.white.setFill()
NSBezierPath(roundedRect: NSRect(x: 190, y: 300, width: 644, height: 500), xRadius: 120, yRadius: 120).fill()
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 290, y: 350)); tail.line(to: NSPoint(x: 290, y: 200)); tail.line(to: NSPoint(x: 470, y: 350)); tail.close(); tail.fill()
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 320, weight: .bold), .foregroundColor: NSColor(srgbRed: 0.25, green: 0.23, blue: 0.69, alpha: 1)]
let mark = "§" as NSString
let dimensions = mark.size(withAttributes: attributes)
mark.draw(at: NSPoint(x: (1024 - dimensions.width) / 2, y: 550 - dimensions.height / 2), withAttributes: attributes)
NSGraphicsContext.restoreGraphicsState()
let url = URL(fileURLWithPath: "iOS/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))

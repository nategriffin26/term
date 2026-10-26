// Renders Term's app icons and their Settings previews:
//   swift scripts/app-icons.swift app/Resources/Assets.xcassets
// Each icon is a prompt chevron and a block cursor on a ground, drawn as
// geometry (no fonts), 1024 px; Xcode makes the smaller sizes. Dusk (Term's
// own theme) is the primary icon, the rest are alternates.
import AppKit

struct Icon {
  let name: String
  let top: UInt32, bottom: UInt32
  let chevron: UInt32, cursor: UInt32
  var primary = false

  /// Its app icon set: the primary is AppIcon, an alternate AppIcon-<name>.
  var set: String { primary ? "AppIcon" : "AppIcon-\(name)" }
}

let icons = [
  Icon(name: "Dusk", top: 0x221D2D, bottom: 0x110E17, chevron: 0xF6F4FA, cursor: 0x7EF0DA, primary: true),
  Icon(name: "Porcelain", top: 0xFBFAFD, bottom: 0xE8E5EF, chevron: 0x15121C, cursor: 0x15121C),
  Icon(name: "Graphite", top: 0x45424E, bottom: 0x2C2A33, chevron: 0xF6F4FA, cursor: 0xF6F4FA),
]

func color(_ rgb: UInt32) -> CGColor {
  CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
}

func render(_ icon: Icon, size: Int) -> Data {
  let s = CGFloat(size) / 1024
  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.scaleBy(x: s, y: s)
  // Ground: top to bottom (CG's y runs up).
  let ground = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(icon.bottom), color(icon.top)] as CFArray,
                          locations: [0, 1])!
  ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1024), options: [])
  // Chevron and cursor, centred as a pair, the cursor a little taller than a line of text.
  let chevronWidth: CGFloat = 116, chevronHalf: CGFloat = 103, gap: CGFloat = 132, cursorWidth: CGFloat = 157, cursorHeight: CGFloat = 314
  let left = (1024 - (chevronWidth + gap + cursorWidth)) / 2
  let chevron = CGMutablePath()
  chevron.move(to: CGPoint(x: left, y: 512 + chevronHalf))
  chevron.addLine(to: CGPoint(x: left + chevronWidth, y: 512))
  chevron.addLine(to: CGPoint(x: left, y: 512 - chevronHalf))
  ctx.addPath(chevron)
  ctx.setStrokeColor(color(icon.chevron))
  ctx.setLineWidth(64)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  ctx.strokePath()
  let cursor = CGRect(x: left + chevronWidth + gap, y: 512 - cursorHeight / 2, width: cursorWidth, height: cursorHeight)
  ctx.addPath(CGPath(roundedRect: cursor, cornerWidth: 20, cornerHeight: 20, transform: nil))
  ctx.setFillColor(color(icon.cursor))
  ctx.fillPath()
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) {
  try! data.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
guard args.count == 2 else { fatalError("usage: swift scripts/app-icons.swift <Assets.xcassets>") }
let assets = args[1]
let fm = FileManager.default
for icon in icons {
  let set = "\(assets)/\(icon.set).appiconset"
  try? fm.createDirectory(atPath: set, withIntermediateDirectories: true)
  write(render(icon, size: 1024), "\(set)/icon.png")
  write(Data("""
    {
      "images" : [
        {
          "filename" : "icon.png",
          "idiom" : "universal",
          "platform" : "ios",
          "size" : "1024x1024"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """.utf8), "\(set)/Contents.json")
}
// Settings › App Icon previews: 64 pt at 3x (app icon sets don't load as images).
func preview(_ png: Data, _ name: String) {
  let image = NSImage(data: png)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
  let ctx = CGContext(data: nil, width: 192, height: 192, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.interpolationQuality = .high
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: 192, height: 192))
  let set = "\(assets)/AppIconPreview-\(name).imageset"
  try? fm.createDirectory(atPath: set, withIntermediateDirectories: true)
  write(NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!, "\(set)/icon.png")
  write(Data("""
    {
      "images" : [
        {
          "filename" : "icon.png",
          "idiom" : "universal",
          "scale" : "3x"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """.utf8), "\(set)/Contents.json")
}
for icon in icons { preview(render(icon, size: 1024), icon.name) }

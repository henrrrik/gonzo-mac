import AppKit

// Vector drawing at each icon resolution, with no runtime image dependency.
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.96, green: 0.93, blue: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196).fill()
        let font = NSFont(name: "Georgia-BoldItalic", size: 650) ?? NSFont.boldSystemFont(ofSize: 650)
        let letter = "G" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1)]
        let metrics = letter.size(withAttributes: attributes)
        letter.draw(at: NSPoint(x: (1024 - metrics.width) / 2 - 15, y: (1024 - metrics.height) / 2 + 28), withAttributes: attributes)
        NSColor(calibratedRed: 0.78, green: 0.20, blue: 0.12, alpha: 1).setStroke()
        let underline = NSBezierPath()
        underline.lineWidth = 28
        underline.lineCapStyle = .round
        underline.move(to: NSPoint(x: 270, y: 245))
        underline.line(to: NSPoint(x: 738, y: 276))
        underline.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let url = URL(fileURLWithPath: directory).appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

import AppKit
import CoreGraphics
import Foundation

/// Renders MailPilot's app icon either as a standard `.iconset` directory (`--iconset <dir>`)
/// for Apple's `iconutil -c icns`, or directly as a `.icns` binary (`<output_icns_path>`).
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate_icon.swift [--iconset <iconset_dir> | <output_icns_path>]\n", stderr)
    exit(1)
}

let isIconsetMode = CommandLine.arguments[1] == "--iconset"
let outputURL = URL(fileURLWithPath: isIconsetMode ? (CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "") : CommandLine.arguments[1])
guard !outputURL.path.isEmpty else {
    fputs("Missing output path\n", stderr)
    exit(1)
}

func renderIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    let scale = size / 1024.0
    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current = context
    guard let cg = context?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }

    cg.scaleBy(x: scale, y: scale)

    let baseRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let cardRect = baseRect.insetBy(dx: 100, dy: 100)
    let cardPath = CGPath(roundedRect: cardRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft outer shadow
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -20), blur: 40, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    cg.addPath(cardPath)
    cg.setFillColor(NSColor(red: 0.16, green: 0.34, blue: 0.88, alpha: 1).cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Sky-to-indigo gradient clipped to squircle
    cg.saveGState()
    cg.addPath(cardPath)
    cg.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradientColors = [
        NSColor(red: 0.13, green: 0.48, blue: 0.98, alpha: 1.0).cgColor,
        NSColor(red: 0.27, green: 0.29, blue: 0.90, alpha: 1.0).cgColor,
        NSColor(red: 0.42, green: 0.20, blue: 0.82, alpha: 1.0).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: [0.0, 0.55, 1.0]) {
        cg.drawLinearGradient(
            gradient,
            start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
            end: CGPoint(x: cardRect.maxX, y: cardRect.minY),
            options: []
        )
    }

    // Specular highlight
    let glowColors = [
        NSColor.white.withAlphaComponent(0.28).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        cg.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: cardRect.minX + 180, y: cardRect.maxY - 140),
            startRadius: 20,
            endCenter: CGPoint(x: cardRect.minX + 180, y: cardRect.maxY - 140),
            endRadius: 520,
            options: []
        )
    }
    cg.restoreGState()

    // Paper plane silhouette
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    let planePath = CGMutablePath()
    planePath.move(to: CGPoint(x: 735, y: 720))
    planePath.addLine(to: CGPoint(x: 270, y: 540))
    planePath.addLine(to: CGPoint(x: 455, y: 465))
    planePath.addLine(to: CGPoint(x: 525, y: 280))
    planePath.closeSubpath()
    cg.addPath(planePath)
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillPath()
    cg.restoreGState()

    // Lower wing crease
    let creasePath = CGMutablePath()
    creasePath.move(to: CGPoint(x: 735, y: 720))
    creasePath.addLine(to: CGPoint(x: 455, y: 465))
    creasePath.addLine(to: CGPoint(x: 525, y: 280))
    creasePath.closeSubpath()
    cg.addPath(creasePath)
    cg.setFillColor(NSColor(red: 0.78, green: 0.87, blue: 1.0, alpha: 0.55).cgColor)
    cg.fillPath()

    // AI sparkles
    func drawSparkle(center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: center.x, y: center.y + radius))
        p.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: center)
        p.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: center)
        p.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: center)
        p.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: center)
        p.closeSubpath()
        cg.addPath(p)
        cg.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        cg.fillPath()
    }
    drawSparkle(center: CGPoint(x: 340, y: 715), radius: 52, alpha: 0.95)
    drawSparkle(center: CGPoint(x: 415, y: 765), radius: 24, alpha: 0.78)

    // Subtle rim
    cg.addPath(cardPath)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    cg.setLineWidth(4)
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    _ = rect
    return bitmap.representation(using: .png, properties: [:])
}

if isIconsetMode {
    let iconsetFiles: [(name: String, px: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    for item in iconsetFiles {
        guard let png = renderIcon(pixels: item.px) else {
            fputs("Failed to render \(item.name)\n", stderr)
            exit(1)
        }
        try png.write(to: outputURL.appendingPathComponent(item.name), options: .atomic)
    }
} else {
    let icnsChunks: [(tag: String, px: Int)] = [
        ("icp4", 16),
        ("icp5", 32),
        ("ic07", 128),
        ("ic08", 256),
        ("ic09", 512),
        ("ic10", 1024),
        ("ic11", 32),   // 16x16@2x
        ("ic12", 64),   // 32x32@2x
        ("ic13", 256),  // 128x128@2x
        ("ic14", 512)   // 256x256@2x
    ]

    var body = Data()
    for chunk in icnsChunks {
        guard let png = renderIcon(pixels: chunk.px) else {
            fputs("Failed to render \(chunk.px)px icon\n", stderr)
            exit(1)
        }
        body.append(Data(chunk.tag.utf8))
        var chunkLen = UInt32(8 + png.count).bigEndian
        body.append(Data(bytes: &chunkLen, count: 4))
        body.append(png)
    }

    var icns = Data("icns".utf8)
    var totalLen = UInt32(8 + body.count).bigEndian
    icns.append(Data(bytes: &totalLen, count: 4))
    icns.append(body)

    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try icns.write(to: outputURL, options: .atomic)
}

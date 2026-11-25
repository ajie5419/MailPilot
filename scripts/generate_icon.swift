import AppKit
import CoreGraphics
import Foundation

/// Renders MailPilot's Sunset Coral Origami Crane app icon either as a standard
/// `.iconset` directory (`--iconset <dir>`) for Apple's `iconutil -c icns`, or directly as `.icns`.
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

func makeContinuousRoundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    // Approximate Apple's continuous-curvature squircle with smooth cubic Beziers.
    let r = min(radius, min(rect.width, rect.height) * 0.5)
    let k: CGFloat = r * 0.4477 // smooth corner control offset
    let minX = rect.minX, maxX = rect.maxX
    let minY = rect.minY, maxY = rect.maxY

    let p = CGMutablePath()
    p.move(to: CGPoint(x: minX + r, y: minY))
    p.addLine(to: CGPoint(x: maxX - r, y: minY))
    p.addCurve(to: CGPoint(x: maxX, y: minY + r),
               control1: CGPoint(x: maxX - k, y: minY),
               control2: CGPoint(x: maxX, y: minY + k))
    p.addLine(to: CGPoint(x: maxX, y: maxY - r))
    p.addCurve(to: CGPoint(x: maxX - r, y: maxY),
               control1: CGPoint(x: maxX, y: maxY - k),
               control2: CGPoint(x: maxX - k, y: maxY))
    p.addLine(to: CGPoint(x: minX + r, y: maxY))
    p.addCurve(to: CGPoint(x: minX, y: maxY - r),
               control1: CGPoint(x: minX + k, y: maxY),
               control2: CGPoint(x: minX, y: maxY - k))
    p.addLine(to: CGPoint(x: minX, y: minY + r))
    p.addCurve(to: CGPoint(x: minX + r, y: minY),
               control1: CGPoint(x: minX, y: minY + k),
               control2: CGPoint(x: minX + k, y: minY))
    p.closeSubpath()
    return p
}

func renderIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    let scale = size / 1024.0

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

    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.scaleBy(x: scale, y: scale)

    let colorSpace = CGColorSpaceCreateDeviceRGB()

    func hexColor(_ hex: UInt32, alpha: CGFloat = 1.0) -> CGColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: alpha).cgColor
    }

    // Standard Apple HIG macOS squircle canvas: 824x824 centered in 1024x1024
    let cardRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cardPath = makeContinuousRoundedRectPath(cardRect, radius: 185.4)

    // 1. Soft macOS Dock ambient drop shadow
    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -14),
        blur: 26,
        color: NSColor(red: 0.08, green: 0.02, blue: 0.05, alpha: 0.30).cgColor
    )
    cg.addPath(cardPath)
    cg.setFillColor(hexColor(0xF45645))
    cg.fillPath()
    cg.restoreGState()

    // 2. Clipped Sunset Coral gradient + warm top radial studio glow
    cg.saveGState()
    cg.addPath(cardPath)
    cg.clip()

    let bgColors = [hexColor(0xFF9233), hexColor(0xF45645), hexColor(0xD1245A)] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.52, 1.0]) {
        cg.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: cardRect.minX + cardRect.width * 0.12, y: cardRect.maxY),
            end: CGPoint(x: cardRect.minX + cardRect.width * 0.88, y: cardRect.minY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    let glowColors = [hexColor(0xFDE68A, alpha: 0.18), hexColor(0xFDE68A, alpha: 0.0)] as CFArray
    if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        let glowCenter = CGPoint(x: 512, y: cardRect.maxY - cardRect.height * 0.22)
        cg.drawRadialGradient(
            glowGrad,
            startCenter: glowCenter,
            startRadius: 0,
            endCenter: glowCenter,
            endRadius: cardRect.width * 0.62,
            options: []
        )
    }

    // 3. Minimalist Geometric Origami Paper Crane (千纸鹤) inside a unified drop-shadow transparency layer
    func cranePt(_ sx: CGFloat, _ sy: CGFloat) -> CGPoint {
        let tx = (sx - 520.0) * 1.012 + 512.0
        let ty = (sy - 456.0) * 1.012 + 524.0
        return CGPoint(x: tx, y: 1024.0 - ty)
    }

    func fillFacet(
        _ rawPoints: [(CGFloat, CGFloat)],
        c1: UInt32,
        c2: UInt32,
        startFrac: (CGFloat, CGFloat) = (0.0, 0.0),
        endFrac: (CGFloat, CGFloat) = (1.0, 1.0),
        alpha: CGFloat = 1.0
    ) {
        let pts = rawPoints.map { cranePt($0.0, $0.1) }
        guard let first = pts.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        for p in pts.dropFirst() {
            path.addLine(to: p)
        }
        path.closeSubpath()

        let box = path.boundingBox
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        let colors = [hexColor(c1, alpha: alpha), hexColor(c2, alpha: alpha)] as CFArray
        if let grad = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 1.0]) {
            let pStart = CGPoint(
                x: box.minX + box.width * startFrac.0,
                y: box.maxY - box.height * startFrac.1
            )
            let pEnd = CGPoint(
                x: box.minX + box.width * endFrac.0,
                y: box.maxY - box.height * endFrac.1
            )
            cg.drawLinearGradient(
                grad,
                start: pStart,
                end: pEnd,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        cg.restoreGState()
    }

    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -16),
        blur: 20,
        color: NSColor(red: 0.51, green: 0.06, blue: 0.20, alpha: 0.32).cgColor
    )
    cg.beginTransparencyLayer(auxiliaryInfo: nil)

    // 1. Far / Upper Wing
    fillFacet([(565, 515), (476, 204), (624, 458)], c1: 0xFFE4C4, c2: 0xFDBA74, startFrac: (0.2, 0.0), endFrac: (0.8, 1.0))
    fillFacet([(476, 204), (438, 495), (565, 515)], c1: 0xFFE4C4, c2: 0xFDBA74, startFrac: (0.2, 0.0), endFrac: (0.8, 1.0), alpha: 0.86)

    // 2. Tail (crisp diagonal sweep up-left)
    fillFacet([(204, 386), (422, 568), (386, 622)], c1: 0xFFEDD5, c2: 0xFED7AA)

    // 3. Rear Lower Body Keel
    fillFacet([(386, 622), (422, 568), (564, 672)], c1: 0xFCA5A5, c2: 0xFB7185)

    // 4. Front Belly Diamond (sealed cleanly into wing & neck hinge)
    fillFacet([(422, 568), (594, 488), (624, 496), (564, 672)], c1: 0xFFF7ED, c2: 0xFFEDD5)

    // 5. Slender Origami Neck (sealed seamlessly into chest & head crown)
    fillFacet([(584, 512), (740, 266), (618, 544)], c1: 0xFED7AA, c2: 0xFDBA74)
    fillFacet([(584, 512), (740, 266), (714, 340), (612, 524)], c1: 0xFFFFFF, c2: 0xFFF7ED)

    // 6. Origami Head & Pointed Beak
    fillFacet([(740, 266), (846, 326), (714, 340)], c1: 0xFFE4E6, c2: 0xFECDD3)
    fillFacet([(740, 266), (846, 326), (732, 308)], c1: 0xFFFFFF, c2: 0xFFF7ED)

    // 7. Hero Near Wing (broad sweeping main origami wing)
    fillFacet([(222, 270), (598, 492), (430, 582)], c1: 0xFFFFFF, c2: 0xFFF5EB)
    fillFacet([(222, 270), (430, 582), (372, 538)], c1: 0xFFEDD5, c2: 0xFED7AA)

    cg.endTransparencyLayer()
    cg.restoreGState()

    cg.restoreGState() // end cardPath clip

    // 4. Delicate luminous rim highlight on the squircle
    cg.addPath(cardPath)
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    cg.setLineWidth(3.5)
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
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

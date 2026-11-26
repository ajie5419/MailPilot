import AppKit
import CoreGraphics
import SwiftUI

/// Reusable AppKit `NSVisualEffectView` wrapper enabling true macOS `.behindWindow`
/// liquid-glass translucency that refracts the live desktop wallpaper.
struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    var isEmphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material {
            nsView.material = material
        }
        if nsView.blendingMode != blendingMode {
            nsView.blendingMode = blendingMode
        }
        if nsView.state != state {
            nsView.state = state
        }
        if nsView.isEmphasized != isEmphasized {
            nsView.isEmphasized = isEmphasized
        }
    }
}

/// Unified Sunset Coral brand palette and adaptive liquid-glass surface tokens.
enum BrandPalette {
    static let coralAmber = Color(red: 1.0, green: 0.557, blue: 0.235)     // #FF8E3C
    static let coral = Color(red: 0.957, green: 0.337, blue: 0.271)         // #F45645
    static let coralRose = Color(red: 0.886, green: 0.212, blue: 0.337)     // #E23656
    /// High-contrast Sunset Coral fill for small white text (>= 5.8:1 WCAG AA).
    static let coralBadge = Color(red: 0.77, green: 0.16, blue: 0.16)       // #C42929

    static var coralGradient: LinearGradient {
        LinearGradient(
            colors: [coralAmber, coral, coralRose],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Rich Sunset Coral gradient with >= 5.1:1 contrast against white button text across all stops.
    static var coralButtonGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.847, green: 0.220, blue: 0.165), // #D8382A
                Color(red: 0.780, green: 0.133, blue: 0.259), // #C72242
                Color(red: 0.651, green: 0.090, blue: 0.294)  // #A6174B
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func floatingCardFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.085) : Color.white.opacity(0.84)
    }

    static func floatingCardBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color.white.opacity(0.92)
    }

    static func floatingCardShadow(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.065)
    }

    static func sidebarSelectionFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.085)
    }

    static func sidebarPillFill(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    static func detailVeil(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.14) : Color.white.opacity(0.14)
    }

    static func sidebarVeil(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.08)
    }
}

/// Renders MailPilot's app icon smoothly with a Sunset Coral squircle fallback.
struct AppBrandIconView: View {
    let size: CGFloat
    var showShadow: Bool = true

    var body: some View {
        Group {
            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .fill(BrandPalette.coralGradient)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: size * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
        .shadow(
            color: showShadow ? Color.black.opacity(0.22) : .clear,
            radius: showShadow ? size * 0.14 : 0,
            y: showShadow ? size * 0.06 : 0
        )
    }
}

/// Renders MailPilot's bespoke Origami Paper Crane silhouette as a crisp macOS
/// menu bar template `NSImage` (`isTemplate = true`) matching `scripts/generate_icon.swift`.
enum CraneTemplateIconRenderer {
    @MainActor private static var cachedMenuBarImage: NSImage?

    @MainActor
    static func menuBarIcon() -> NSImage {
        if let cached = cachedMenuBarImage {
            return cached
        }
        let image = renderTemplateImage(pointSize: NSSize(width: 21, height: 16))
        cachedMenuBarImage = image
        return image
    }

    static func renderTemplateImage(pointSize: NSSize) -> NSImage {
        let image = NSImage(size: pointSize, flipped: false) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else {
                return false
            }
            cg.setAllowsAntialiasing(true)
            cg.setShouldAntialias(true)

            // Tight bounding box of the origami crane vertices in 1024-space:
            // x: 204..846 (width 642), y: 204..672 (height 468)
            let srcMinX: CGFloat = 196
            let srcMinY: CGFloat = 196
            let srcWidth: CGFloat = 658
            let srcHeight: CGFloat = 484

            let insetRect = rect.insetBy(dx: 0.5, dy: 0.5)
            let scale = min(insetRect.width / srcWidth, insetRect.height / srcHeight)
            let drawnW = srcWidth * scale
            let drawnH = srcHeight * scale
            let originX = insetRect.minX + (insetRect.width - drawnW) * 0.5
            let originY = insetRect.minY + (insetRect.height - drawnH) * 0.5

            func pt(_ sx: CGFloat, _ sy: CGFloat) -> CGPoint {
                let x = originX + (sx - srcMinX) * scale
                let y = originY + (srcHeight - (sy - srcMinY)) * scale
                return CGPoint(x: x, y: y)
            }

            func fill(_ rawPoints: [(CGFloat, CGFloat)], alpha: CGFloat) {
                guard let first = rawPoints.first else { return }
                let path = CGMutablePath()
                path.move(to: pt(first.0, first.1))
                for p in rawPoints.dropFirst() {
                    path.addLine(to: pt(p.0, p.1))
                }
                path.closeSubpath()
                cg.addPath(path)
                cg.setFillColor(NSColor.black.withAlphaComponent(alpha).cgColor)
                cg.fillPath()
            }

            // Faceted alpha hierarchy preserves origami wing depth when macOS tints the template icon.
            // 1. Far / Upper Wing
            fill([(565, 515), (476, 204), (624, 458)], alpha: 0.78)
            fill([(476, 204), (438, 495), (565, 515)], alpha: 0.72)

            // 2. Tail
            fill([(204, 386), (422, 568), (386, 622)], alpha: 0.92)

            // 3. Rear Lower Body Keel
            fill([(386, 622), (422, 568), (564, 672)], alpha: 0.68)

            // 4. Front Belly Diamond
            fill([(422, 568), (594, 488), (624, 496), (564, 672)], alpha: 0.88)

            // 5. Slender Origami Neck
            fill([(584, 512), (740, 266), (618, 544)], alpha: 0.95)
            fill([(584, 512), (740, 266), (714, 340), (612, 524)], alpha: 1.0)

            // 6. Origami Head & Pointed Beak
            fill([(740, 266), (846, 326), (714, 340)], alpha: 0.92)
            fill([(740, 266), (846, 326), (732, 308)], alpha: 1.0)

            // 7. Hero Near Wing
            fill([(222, 270), (598, 492), (430, 582)], alpha: 1.0)
            fill([(222, 270), (430, 582), (372, 538)], alpha: 0.90)

            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MailPilot"
        return image
    }
}

/// Resolves the exact `NSWindow` hosting a SwiftUI root view without guessing from `NSApp.windows`.
struct MainWindowResolver: NSViewRepresentable {
    let onResolve: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowResolverNSView {
        let view = WindowResolverNSView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowResolverNSView, context: Context) {
        nsView.onResolve = onResolve
        if let window = nsView.window {
            onResolve(window)
        }
    }

    final class WindowResolverNSView: NSView {
        var onResolve: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let callback = onResolve
            Task { @MainActor in
                callback?(window)
            }
        }
    }
}

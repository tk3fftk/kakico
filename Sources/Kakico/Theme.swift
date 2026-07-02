import SwiftUI
import AppKit

// MARK: - Miro color tokens (docs/DESIGN.md §1)

extension Color {
    // Board & Chrome (Light)
    static let miroBoard          = Color(red: 0.961, green: 0.961, blue: 0.969) // #F5F5F7
    static let miroGrid           = Color(red: 0.843, green: 0.843, blue: 0.871) // #D7D7DE
    static let miroChrome         = Color.white                                   // #FFFFFF
    static let miroSurfaceGray    = Color(red: 0.945, green: 0.945, blue: 0.957) // #F1F1F4
    static let miroSurfacePressed = Color(red: 0.902, green: 0.902, blue: 0.922) // #E6E6EB
    static let miroDivider        = Color(red: 0.890, green: 0.890, blue: 0.910) // #E3E3E8

    // Board & Chrome (Dark)
    static let miroDarkCanvas   = Color(red: 0.106, green: 0.106, blue: 0.122) // #1B1B1F
    static let miroDarkBoard    = Color(red: 0.125, green: 0.125, blue: 0.141) // #202024
    static let miroDarkGrid     = Color(red: 0.220, green: 0.220, blue: 0.247) // #38383F
    static let miroDarkSurface1 = Color(red: 0.149, green: 0.149, blue: 0.169) // #26262B
    static let miroDarkSurface2 = Color(red: 0.192, green: 0.192, blue: 0.220) // #313138

    // Text
    static let miroInk             = Color(red: 0.020, green: 0.000, blue: 0.220) // #050038
    static let miroTextSecondary   = Color(red: 0.420, green: 0.420, blue: 0.482) // #6B6B7B
    static let miroTextTertiary    = Color(red: 0.604, green: 0.604, blue: 0.643) // #9A9AA4
    static let miroDarkTextPrimary = Color(red: 0.925, green: 0.925, blue: 0.937) // #ECECEF

    // Brand / Interactive
    static let miroYellow        = Color(red: 1.000, green: 0.816, blue: 0.184) // #FFD02F
    static let miroYellowPressed = Color(red: 0.910, green: 0.722, blue: 0.000) // #E8B800
    static let miroBlue          = Color(red: 0.259, green: 0.384, blue: 1.000) // #4262FF
    static let miroBluePressed   = Color(red: 0.184, green: 0.290, blue: 0.878) // #2F4AE0

    // Semantic
    static let miroSuccess = Color(red: 0.180, green: 0.647, blue: 0.416) // #2EA56A
}

extension NSColor {
    /// Selection chrome; identical across light and dark themes (DESIGN.md §7).
    static let miroBlue = NSColor(srgbRed: 0.259, green: 0.384, blue: 1.000, alpha: 1)
}

// MARK: - Scheme-resolving helpers

enum MiroTheme {
    static func board(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .miroDarkBoard : .miroBoard
    }
    static func grid(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .miroDarkGrid : .miroGrid
    }
    static func textPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .miroDarkTextPrimary : .miroInk
    }
    static func textSecondary(_ scheme: ColorScheme) -> Color {
        // Raw #6B6B7B lacks contrast on dark material.
        scheme == .dark ? Color.miroDarkTextPrimary.opacity(0.65) : .miroTextSecondary
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .miroDarkSurface2 : .miroSurfaceGray
    }
}

// MARK: - Typography (DESIGN.md §2, mapped to system fonts)

extension Font {
    static let miroBody    = Font.system(size: 16)
    static let miroControl = Font.system(size: 15, weight: .semibold)
    static let miroButton  = Font.system(size: 15, weight: .bold)
    static let miroCaption = Font.system(size: 12, weight: .semibold)
}

// MARK: - Dot grid (DESIGN.md §3, fixed spacing — no pan/zoom)

struct MiroGrid: View {
    let color: Color
    var spacing: CGFloat = 28

    // A per-dot Canvas loop is O(area) and re-runs on every frame of a live
    // window resize; tiling a single-dot image keeps the cost O(1).
    @MainActor private static var tileCache: [Color: NSImage] = [:]

    private static func tile(color: Color, spacing: CGFloat) -> NSImage {
        if let cached = tileCache[color] { return cached }
        let ns = NSColor(color)
        // flipped: true puts the dot at the tile's top-left, matching the
        // previous Canvas placement.
        let image = NSImage(size: NSSize(width: spacing, height: spacing),
                            flipped: true) { _ in
            ns.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 1.5, height: 1.5)).fill()
            return true
        }
        tileCache[color] = image
        return image
    }

    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(nsImage: Self.tile(color: color, spacing: spacing))))
    }
}

// MARK: - Button styles (DESIGN.md §3, §5)

struct MiroPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}

struct MiroPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.miroButton)
                .foregroundStyle(Color.miroInk)
                .padding(.vertical, 10).padding(.horizontal, 20)
                .background(Color.miroYellow)
                .clipShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(MiroPressStyle())
    }
}

struct MiroSecondaryButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.miroControl)
                .foregroundStyle(MiroTheme.textPrimary(scheme))
                .padding(.vertical, 10).padding(.horizontal, 20)
                .background(MiroTheme.surface(scheme))
                .clipShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(MiroPressStyle())
    }
}

/// Icon-tile button chrome: hover and pressed background fills so clicks are
/// clearly acknowledged even for actions with no visible result.
struct MiroTileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: Configuration
        @Environment(\.colorScheme) private var scheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        private var fill: Color {
            if configuration.isPressed {
                return scheme == .dark ? .miroDarkGrid : .miroSurfacePressed
            }
            if hovering {
                return scheme == .dark ? .miroDarkSurface2 : .miroSurfaceGray
            }
            return .clear
        }

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 11).fill(fill))
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7),
                           value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Floating panel chrome (DESIGN.md §3 toolbar, §7 dark elevation)

private struct MiroFloatingPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.22), radius: 16, y: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.miroDivider.opacity(0.5), lineWidth: 1)
            )
    }
}

extension View {
    func miroFloatingPanel() -> some View { modifier(MiroFloatingPanel()) }
}

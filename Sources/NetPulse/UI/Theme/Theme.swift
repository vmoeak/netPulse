import SwiftUI
import AppKit

/// The app's palette. Accent colors come from the original NetPulse.dc.html
/// design; everything that sits on a surface adapts to Light and Dark
/// Appearance, since the window is now translucent and shows the desktop
/// through its glass.
enum Theme {
    static let accentBlue = Color(hex: 0x0A84FF)
    static let upOrange = Color(hex: 0xF0A020)
    static let upOrangeText = adaptive(light: 0xC47A00, dark: 0xFFB340)
    static let upOrangeTextAlt = adaptive(light: 0xE08600, dark: 0xFFB340)

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    /// Numbers that matter less than the row's main value (a host's rate).
    static let textMuted = adaptive(light: 0x4A4A4F, dark: 0xC7C7CC)

    static let hairline = Color.primary.opacity(0.09)
    static let hairlineLight = Color.primary.opacity(0.06)
    /// Resting fill for inset controls and cards on a content surface.
    static let fill = Color.primary.opacity(0.05)
    static let fillStrong = Color.primary.opacity(0.08)

    /// The app list: light enough that the window's glass shows through.
    static let paneBackground = adaptive(light: 0xFBFBFD, dark: 0x1C1C1F, opacity: 0.62)
    /// The detail and full-width panes, where tables are read closely.
    static let contentBackground = adaptive(light: 0xFFFFFF, dark: 0x1E1E21, opacity: 0.86)

    static let rangeToday = Color(hex: 0x0A84FF)
    static let rangeWeek = Color(hex: 0x30C25F)
    static let rangeMonth = Color(hex: 0xF0A020)
    static let rangeAll = Color(hex: 0xA35CD8)

    /// A faint wash over the window's base material, so the floating glass
    /// has some color to refract instead of reading as plain gray.
    static let windowTint = LinearGradient(
        colors: [accentBlue.opacity(0.14), rangeAll.opacity(0.08), upOrange.opacity(0.07)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let panelRadius: CGFloat = 18
    static let cardRadius: CGFloat = 14
    static let rowRadius: CGFloat = 10

    static func adaptive(light: UInt32, dark: UInt32, opacity: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: opacity)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

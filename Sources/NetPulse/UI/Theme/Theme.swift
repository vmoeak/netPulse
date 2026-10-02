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

    /// The one content surface the list and detail share, opaque like a
    /// Finder or System Settings content area: only the sidebar is glass.
    static let contentSurface = Color(nsColor: .controlBackgroundColor)
    /// Kept for the machine-wide panes, which sit on the same surface.
    static let paneBackground = contentSurface
    static let contentBackground = contentSurface

    /// Selected rows: a soft accent wash, as in macOS 26 sidebars and lists.
    static let selectionFill = accentBlue.opacity(0.15)
    /// The raised pill behind a segmented control's chosen segment.
    static let segmentFill = adaptive(light: 0xFFFFFF, dark: 0x636366, opacity: 1)
    /// A base under toolbar glass, so the capsules keep their shape on the
    /// dark content surface, where glass alone barely separates.
    static let controlFillDark = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.07) : NSColor.clear
    })
    /// Fill for chart cards and other inset regions on the content surface.
    static let cardFill = Color.primary.opacity(0.035)

    static let rangeToday = Color(hex: 0x0A84FF)
    static let rangeWeek = Color(hex: 0x30C25F)
    static let rangeMonth = Color(hex: 0xF0A020)
    static let rangeAll = Color(hex: 0xA35CD8)

    static let panelRadius: CGFloat = 18
    static let cardRadius: CGFloat = 10
    static let rowRadius: CGFloat = 8

    /// Horizontal padding of every content pane, and the height every pane
    /// header shares with the traffic lights' title-bar strip.
    static let contentPadding: CGFloat = 16
    static let headerHeight: CGFloat = 52
    /// Search field, sort toggle and window menu all share this height.
    static let controlHeight: CGFloat = 28

    static func adaptive(light: UInt32, dark: UInt32, opacity: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: opacity)
        })
    }
}

/// The app's whole type scale. Anything that shows a number also takes
/// `.monospacedDigit()` so columns of figures don't jitter as they update.
enum Typo {
    /// Captions, column headers, secondary lines.
    static let caption = Font.system(size: 11, weight: .medium)
    static let captionRegular = Font.system(size: 11)
    /// Table body.
    static let body = Font.system(size: 12)
    static let bodyMedium = Font.system(size: 12, weight: .medium)
    /// Row titles.
    static let rowTitle = Font.system(size: 13, weight: .medium)
    static let rowTitleRegular = Font.system(size: 13)
    /// Pane titles.
    static let title = Font.system(size: 15, weight: .semibold)
    /// Stat values.
    static let stat = Font.system(size: 20, weight: .semibold, design: .rounded)
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

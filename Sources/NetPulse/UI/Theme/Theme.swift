import SwiftUI

/// Colors ported directly from the hex/rgba literals in NetPulse.dc.html.
enum Theme {
    static let accentBlue = Color(hex: 0x0A84FF)
    static let upOrange = Color(hex: 0xF0A020)
    static let upOrangeText = Color(hex: 0xC47A00)
    static let upOrangeTextAlt = Color(hex: 0xE08600)

    static let textPrimary = Color(hex: 0x1D1D1F)
    static let textSecondary = Color(hex: 0x8A8A8E)
    static let textTertiary = Color(hex: 0xA1A1A6)

    static let sidebarBackground = Color(hex: 0xF6F6F8).opacity(0.86)
    static let paneBackground = Color(hex: 0xFBFBFD)
    static let hairline = Color.black.opacity(0.09)
    static let hairlineLight = Color.black.opacity(0.07)

    static let rangeToday = Color(hex: 0x0A84FF)
    static let rangeWeek = Color(hex: 0x30C25F)
    static let rangeMonth = Color(hex: 0xF0A020)
    static let rangeAll = Color(hex: 0xA35CD8)

    static let windowBackdrop = LinearGradient(
        colors: [Color(hex: 0x1B2A4A), Color(hex: 0x2D3F63), Color(hex: 0x6B5B7D), Color(hex: 0xC98A72)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

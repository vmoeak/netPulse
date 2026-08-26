import SwiftUI

extension Color {
    /// e.g. `Color(hex: 0x0A84FF)` — matches the hex literals used throughout
    /// the original NetPulse.dc.html design so palette values can be ported 1:1.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

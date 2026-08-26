import SwiftUI

/// Assigns each app a stable colored-square badge. A handful of well-known
/// bundle IDs get the exact gradients from the original design; anything
/// else gets a deterministic pick from a fallback palette so the same app
/// always looks the same across launches.
enum AppPalette {
    private static let knownByBundleID: [String: AppBadge] = [
        "com.google.Chrome": AppBadge(initials: "C", colorTop: Color(hex: 0x4C8BF5), colorBottom: Color(hex: 0x2B6AE0)),
        "com.getdropbox.dropbox": AppBadge(initials: "D", colorTop: Color(hex: 0x3D8BFF), colorBottom: Color(hex: 0x0F5BD8)),
        "com.spotify.client": AppBadge(initials: "S", colorTop: Color(hex: 0x37D67A), colorBottom: Color(hex: 0x12A352)),
        "com.tinyspeck.slackmacgap": AppBadge(initials: "SL", colorTop: Color(hex: 0x7A55C9), colorBottom: Color(hex: 0x4A1D96)),
        "com.apple.dt.Xcode": AppBadge(initials: "X", colorTop: Color(hex: 0x5B9DFB), colorBottom: Color(hex: 0x1C5FD4)),
        "us.zoom.xos": AppBadge(initials: "Z", colorTop: Color(hex: 0x3D9BFF), colorBottom: Color(hex: 0x1466D6)),
        "com.apple.mail": AppBadge(initials: "M", colorTop: Color(hex: 0x4FA3FF), colorBottom: Color(hex: 0x1A6FE0)),
        "com.docker.docker": AppBadge(initials: "DK", colorTop: Color(hex: 0x3AA9E0), colorBottom: Color(hex: 0x1471B8)),
        "com.figma.Desktop": AppBadge(initials: "F", colorTop: Color(hex: 0xF2643F), colorBottom: Color(hex: 0xC93A1E)),
        "com.apple.softwareupdated": AppBadge(initials: "SU", colorTop: Color(hex: 0x98989D), colorBottom: Color(hex: 0x6C6C70)),
    ]

    private static let fallbackGradients: [(Color, Color)] = [
        (Color(hex: 0x4C8BF5), Color(hex: 0x2B6AE0)),
        (Color(hex: 0x37D67A), Color(hex: 0x12A352)),
        (Color(hex: 0xF2643F), Color(hex: 0xC93A1E)),
        (Color(hex: 0x7A55C9), Color(hex: 0x4A1D96)),
        (Color(hex: 0xF0A020), Color(hex: 0xC47A00)),
        (Color(hex: 0x3AA9E0), Color(hex: 0x1471B8)),
        (Color(hex: 0xE0527A), Color(hex: 0xB8235A)),
        (Color(hex: 0x63B36C), Color(hex: 0x2E8A3C)),
    ]

    static func badge(bundleID: String, name: String) -> AppBadge {
        if let known = knownByBundleID[bundleID] { return known }
        let index = abs(name.hashValue) % fallbackGradients.count
        let (top, bottom) = fallbackGradients[index]
        return AppBadge(initials: initials(for: name), colorTop: top, colorBottom: bottom)
    }

    static func initials(for name: String) -> String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2, let f1 = words[0].first, let f2 = words[1].first {
            return String([f1, f2]).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

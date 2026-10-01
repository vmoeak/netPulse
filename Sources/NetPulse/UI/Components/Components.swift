import SwiftUI
import AppKit

/// Ports the `poly()` helper from the design's JS: normalizes a value
/// series against its own max and lays it out left-to-right. Used for the
/// per-app trend sparklines and the detail pane's throughput lines.
struct Sparkline: Shape {
    var values: [Double]
    var verticalPadding: CGFloat = 3
    /// A shared top of scale, so lines drawn side by side compare; nil
    /// scales to this line's own peak.
    var scaleMax: Double? = nil

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        // A floor only to avoid dividing by zero: the old 1 KB/s floor drew
        // an app idling at a few hundred bytes a second as a flat line.
        let maxValue = max(scaleMax ?? values.max() ?? 1, 0.01)
        let n = values.count
        let usableHeight = max(0, rect.height - verticalPadding * 2)
        for (i, v) in values.enumerated() {
            let x = rect.minX + (CGFloat(i) / CGFloat(n - 1)) * rect.width
            let y = rect.minY + rect.height - verticalPadding - CGFloat(v / maxValue) * usableHeight
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

/// Same normalization as `Sparkline`, closed into a filled area against the
/// bottom edge — used for the throughput chart's download fill.
struct SparklineArea: Shape {
    var values: [Double]
    var verticalPadding: CGFloat = 8
    var scaleMax: Double? = nil

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let maxValue = max(scaleMax ?? values.max() ?? 1, 0.01)
        let n = values.count
        let usableHeight = max(0, rect.height - verticalPadding * 2)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for (i, v) in values.enumerated() {
            let x = rect.minX + (CGFloat(i) / CGFloat(n - 1)) * rect.width
            let y = rect.minY + rect.height - verticalPadding - CGFloat(v / maxValue) * usableHeight
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Colored-gradient-square-with-initials app icon.
struct IconBadge: View {
    let badge: AppBadge
    var size: CGFloat = 28
    var cornerRadius: CGFloat = 7
    var fontSize: CGFloat = 12

    var body: some View {
        if let icon = badge.bundleID.flatMap(AppIconCache.icon(for:)) {
            // App icons carry their own shape and margin, so they're drawn
            // slightly larger to match the squares' visual weight.
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 1.15, height: size * 1.15)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(badge.gradient)
                .frame(width: size, height: size)
                .overlay(
                    Text(badge.initials)
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }
}

/// Installed apps' icons by bundle ID. Looked up once per ID: rows redraw
/// every second, and a miss (a helper with no findable bundle) is cached too.
@MainActor enum AppIconCache {
    private static var icons: [String: NSImage?] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleID] = icon
        return icon
    }
}

/// One column of the detail pane's stat strip: a caption over a large
/// figure, with no box around it; the strip draws the dividers between.
struct StatTile: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Typo.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            RateText(value, font: Typo.stat, unitFont: .system(size: 13, weight: .medium, design: .rounded),
                     color: valueColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A figure such as "12.4 KB/s" or "3.1 GB", with the unit set quieter than
/// the number so a column of values reads by magnitude first.
struct RateText: View {
    let number: String
    let unit: String
    let font: Font
    let unitFont: Font
    let color: Color

    init(_ text: String, font: Font, unitFont: Font? = nil, color: Color) {
        if let space = text.lastIndex(of: " ") {
            number = String(text[..<space])
            unit = String(text[text.index(after: space)...])
        } else {
            number = text
            unit = ""
        }
        self.font = font
        self.unitFont = unitFont ?? font
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(number).font(font).foregroundStyle(color)
            if !unit.isEmpty {
                Text(unit).font(unitFont).foregroundStyle(Theme.textSecondary)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}

/// The card every chart sits on: a faint fill and a 10pt continuous corner.
struct ChartCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// Faint horizontal guides behind a chart: a baseline and two grid lines.
struct ChartGrid: View {
    var lines: Int = 3

    var body: some View {
        GeometryReader { geo in
            Path { path in
                for i in 0..<lines {
                    let y = geo.size.height * CGFloat(i) / CGFloat(max(lines - 1, 1))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Theme.hairlineLight, style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        }
    }
}

/// A legend entry: a 6pt dot and its label.
struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).lineLimit(1)
        }
    }
}

/// The colored dot + glow ring used by the sidebar's time-range picker.
struct RangeDot: View {
    let color: Color
    let selected: Bool

    var body: some View {
        Circle()
            .fill(selected ? color : Color.primary.opacity(0.2))
            .frame(width: 7, height: 7)
            .frame(width: 18, height: 16)
    }
}

/// A thin fill-percentage bar (used by the sidebar's 下载/上传 totals and
/// the domain table's relative-share backdrop).
struct MeterBar: View {
    var fraction: Double
    var color: Color
    var trackColor: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(trackColor)
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
    }
}

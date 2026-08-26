import SwiftUI

/// Ports the `poly()` helper from the design's JS: normalizes a value
/// series against its own max and lays it out left-to-right. Used for the
/// per-app trend sparklines and the detail pane's throughput lines.
struct Sparkline: Shape {
    var values: [Double]
    var verticalPadding: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let maxValue = max(values.max() ?? 1, 1)
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

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let maxValue = max(values.max() ?? 1, 1)
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

/// One of the four stat cells at the top of the detail pane.
struct StatTile: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
    }
}

/// The colored dot + glow ring used by the sidebar's time-range picker.
struct RangeDot: View {
    let color: Color
    let selected: Bool

    var body: some View {
        Circle()
            .fill(selected ? color : Color.black.opacity(0.14))
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(color.opacity(selected ? 0.22 : 0), lineWidth: 3)
                    .frame(width: 14, height: 14)
            )
            .frame(width: 16, height: 16)
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

import SwiftUI

/// The machine's traffic over the list's rate window, stacked by app: which
/// app a spike belongs to shows as the band that swells. Top five apps get
/// their own color, the rest share 其他.
struct TrafficStackChart: View {
    let layers: [NetworkMonitorEngine.StackLayer]
    let window: RateWindow

    private static let palette: [Color] = [
        Color(hex: 0x0A84FF), Color(hex: 0x30C25F), Color(hex: 0xF0A020),
        Color(hex: 0xA35CD8), Color(hex: 0xE0527A), Color(hex: 0x98989D),
    ]

    var body: some View {
        let peak = stackedTotals.max() ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window == .live ? "近 1 分钟流量" : "\(window.label)流量")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("峰值 \(Format.rate(peak))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            ZStack {
                if peak == 0 {
                    Text("这段时间没有流量").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                } else {
                    // Drawn top layer first, each as the band from the
                    // baseline to its cumulative sum, so later (lower)
                    // layers paint over the upper ones' lower part.
                    ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { index, _ in
                        StackBand(values: cumulative(through: index), peak: peak)
                            .fill(Self.palette[min(index, Self.palette.count - 1)].opacity(0.85))
                    }
                }
            }
            .frame(height: 64)
            legend
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                HStack(spacing: 4) {
                    Circle().fill(Self.palette[min(index, Self.palette.count - 1)]).frame(width: 6, height: 6)
                    Text(layer.name).lineLimit(1)
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.textSecondary)
    }

    private var stackedTotals: [Double] { cumulative(through: layers.count - 1) }

    private func cumulative(through index: Int) -> [Double] {
        guard index >= 0, let first = layers.first else { return [] }
        var sums = Array(repeating: 0.0, count: first.values.count)
        for layer in layers.prefix(index + 1) {
            for i in sums.indices where i < layer.values.count { sums[i] += layer.values[i] }
        }
        return sums
    }
}

/// Area from the bottom edge up to `values`, scaled against `peak`.
private struct StackBand: Shape {
    let values: [Double]
    let peak: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, peak > 0 else { return path }
        let step = rect.width / CGFloat(values.count - 1)
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for (i, v) in values.enumerated() {
            path.addLine(to: CGPoint(x: rect.minX + CGFloat(i) * step,
                                     y: rect.maxY - CGFloat(v / peak) * rect.height))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

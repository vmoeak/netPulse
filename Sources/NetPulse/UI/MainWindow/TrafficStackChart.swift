import SwiftUI

/// The machine's traffic over the list's rate window, stacked by app: which
/// app a spike belongs to shows as the band that swells. Top five apps get
/// their own color, the rest share 其他.
struct TrafficStackChart: View {
    let layers: [NetworkMonitorEngine.StackLayer]
    let window: RateWindow

    /// Softened system hues, one per band; the legend uses the same
    /// colors so a band and its dot always match. 其他 is neutral gray.
    private static let palette: [Color] = [
        Color(hex: 0x5B9CF5), Color(hex: 0x5EC28A), Color(hex: 0xE9AE52),
        Color(hex: 0xA488DC), Color(hex: 0xE07F96), Color(hex: 0xA9A9B0),
    ]

    private static func color(_ index: Int) -> Color {
        palette[min(index, palette.count - 1)]
    }

    var body: some View {
        let peak = stackedTotals.max() ?? 0
        ChartCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(window == .live ? "近 1 分钟流量" : "\(window.label)流量")
                        .font(Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("峰值 \(Format.rate(peak))")
                        .font(Typo.captionRegular)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
                ZStack {
                    ChartGrid()
                    if peak == 0 {
                        Text("这段时间没有流量").font(Typo.captionRegular).foregroundStyle(Theme.textTertiary)
                    } else {
                        // Drawn top layer first, each as the band from the
                        // baseline to its cumulative sum, so later (lower)
                        // layers paint over the upper ones' lower part.
                        ForEach(Array(layers.enumerated().reversed()), id: \.element.id) { index, _ in
                            StackBand(values: cumulative(through: index), peak: peak * 1.08)
                                .fill(Self.color(index))
                        }
                    }
                }
                .frame(height: 56)
                legend
            }
            .padding(12)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.bottom, 8)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { index, layer in
                LegendDot(color: Self.color(index), label: layer.name)
            }
        }
        .font(Typo.captionRegular)
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

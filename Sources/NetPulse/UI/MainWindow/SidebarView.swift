import SwiftUI

/// Left nav column: matches lines 86-152 of NetPulse.dc.html — nav items,
/// the colored-dot time-range picker, and the bottom download/upload
/// totals with progress bars. Traffic-light window controls aren't drawn
/// here; they're the real ones the OS provides for the window.
struct SidebarView: View {
    @ObservedObject var engine: NetworkMonitorEngine

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                sectionLabel("监控")

                NavRow(systemImage: "square.grid.2x2", title: "所有 App", trailing: "\(engine.apps.count)", selected: true)
                NavRow(systemImage: "point.3.filled.connected.trianglepath.dotted", title: "活跃连接", trailing: "\(engine.connectionCount)", selected: false)
                NavRow(systemImage: "globe", title: "域名总览", trailing: nil, selected: false)

                sectionLabel("统计区间").padding(.top, 14)

                ForEach(TimeRange.allCases) { range in
                    HStack(spacing: 9) {
                        RangeDot(color: range.dotColor, selected: engine.range == range)
                        Text(range.label)
                            .font(.system(size: 13, weight: engine.range == range ? .semibold : .regular))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(engine.range == range ? Color.black.opacity(0.075) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { engine.range = range }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 10) {
                totalsRow(label: "下载", value: Format.rate(engine.totalDownKBps), valueColor: Theme.accentBlue, barColor: Theme.accentBlue, trackColor: Theme.accentBlue.opacity(0.16), fraction: engine.totalDownPct)
                totalsRow(label: "上传", value: Format.rate(engine.totalUpKBps), valueColor: Theme.upOrangeTextAlt, barColor: Theme.upOrange, trackColor: Theme.upOrange.opacity(0.16), fraction: engine.totalUpPct)
                statusLine
            }
            .padding(14)
            .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .top)
        }
        .frame(width: 216)
        .background(Theme.sidebarBackground)
        .overlay(Rectangle().fill(Theme.hairline).frame(width: 0.5), alignment: .trailing)
    }

    private var statusLine: some View {
        Group {
            switch engine.status {
            case .starting:
                Text("正在启动监控…")
            case .ok:
                Text("Wi‑Fi · 正在监控")
            case .degraded(let message), .unavailable(let message):
                Text(message).foregroundStyle(.orange)
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(3)
        .padding(.top, 2)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }

    private func totalsRow(label: String, value: String, valueColor: Color, barColor: Color, trackColor: Color, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .lastTextBaseline) {
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(valueColor).monospacedDigit()
            }
            MeterBar(fraction: fraction, color: barColor, trackColor: trackColor)
                .frame(height: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}

private struct NavRow: View {
    let systemImage: String
    let title: String
    let trailing: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, height: 16)
            Text(title).font(.system(size: 13, weight: selected ? .medium : .regular))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(selected ? .white.opacity(0.8) : Theme.textSecondary)
            }
        }
        .foregroundStyle(selected ? .white : Theme.textPrimary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Theme.accentBlue : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

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

                ForEach(SidebarSection.allCases) { section in
                    NavRow(systemImage: section.systemImage,
                           title: section.label,
                           trailing: badgeCount(for: section),
                           selected: engine.section == section)
                        .contentShape(Rectangle())
                        .onTapGesture { engine.section = section }
                }

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

            deepModeBox

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

    /// 深度模式 puts NetPulse in the data path, so the switch says what it
    /// does and the hint below carries the one manual step (pointing the
    /// system proxy here) rather than the app changing it behind the user.
    private var deepModeBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { engine.deepModeEnabled },
                                 set: { engine.setDeepMode($0) })) {
                Text("深度模式")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Text(engine.deepModeEnabled
                 ? engine.deepModeHint
                 : "开启后由 NetPulse 中转代理流量，域名与字节数从估算变为实测。")
                .font(.system(size: 10))
                .foregroundStyle(engine.deepModeEnabled ? Theme.accentBlue : Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if engine.deepModeEnabled {
                Text("关闭 NetPulse 前请先关掉此模式，否则代理指向会失效。")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .top)
    }

    private func badgeCount(for section: SidebarSection) -> String {
        switch section {
        case .apps: return "\(engine.apps.count)"
        case .connections: return "\(engine.connectionCount)"
        case .domains: return "\(engine.domainRollups.count)"
        }
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

import SwiftUI

/// Left nav column: matches lines 86-152 of NetPulse.dc.html — nav items,
/// the colored-dot time-range picker, and the bottom download/upload
/// totals with progress bars. Traffic-light window controls aren't drawn
/// here; they're the real ones the OS provides for the window, and the
/// sidebar is a floating pane of glass with room left at its top for them.
struct SidebarView: View {
    @ObservedObject var engine: NetworkMonitorEngine

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                sectionLabel("监控")

                ForEach(SidebarSection.allCases) { section in
                    NavRow(systemImage: section.systemImage,
                           title: section.label,
                           trailing: badgeCount(for: section),
                           selected: engine.section == section)
                        .contentShape(Rectangle())
                        .onTapGesture { engine.section = section }
                }

                sectionLabel("统计区间").padding(.top, 16)

                ForEach(TimeRange.allCases) { range in
                    let selected = engine.range == range
                    HStack(spacing: 8) {
                        RangeDot(color: range.dotColor, selected: selected)
                        Text(range.label)
                            .font(Typo.rowTitleRegular)
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? Theme.selectionFill : Color.clear,
                                in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { engine.range = range }
                }
            }
            .padding(.horizontal, 8)
            // Clears the traffic lights, which sit on the glass.
            .padding(.top, 44)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 12) {
                totalsRow(label: "下载", value: Format.rate(engine.totalDownKBps), valueColor: Theme.accentBlue, barColor: Theme.accentBlue, trackColor: Theme.accentBlue.opacity(0.16), fraction: engine.totalDownPct)
                totalsRow(label: "上传", value: Format.rate(engine.totalUpKBps), valueColor: Theme.upOrangeTextAlt, barColor: Theme.upOrange, trackColor: Theme.upOrange.opacity(0.16), fraction: engine.totalUpPct)
                statusLine
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            // Set apart by a hairline rather than a filled card, so the
            // sidebar reads as one pane.
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.horizontal, 16)
            }
        }
        .frame(maxHeight: .infinity)
        .glassSurface(in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        // Floats clear of the window's edges, like the macOS 26 sidebar.
        .padding(8)
        .frame(width: PaneWidth.sidebar)
    }

    private func badgeCount(for section: SidebarSection) -> String {
        switch section {
        case .apps: return "\(engine.listedApps.count)"
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
                // nettop counts every interface, so naming one was a guess.
                Text("正在监控")
            case .degraded(let message), .unavailable(let message):
                Text(message).foregroundStyle(.orange)
            }
        }
        .font(Typo.captionRegular)
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(3)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Typo.caption)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 4)
    }

    private func totalsRow(label: String, value: String, valueColor: Color, barColor: Color, trackColor: Color, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Typo.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                RateText(value, font: .system(size: 13, weight: .semibold), color: valueColor)
            }
            MeterBar(fraction: fraction, color: barColor.opacity(0.85), trackColor: Color.primary.opacity(0.06))
                .frame(height: 3)
                .clipShape(Capsule())
        }
    }
}

private struct NavRow: View {
    let systemImage: String
    let title: String
    let trailing: String?
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(selected ? Theme.accentBlue : Theme.textSecondary)
                .frame(width: 18)
            Text(title)
                .font(Typo.rowTitleRegular)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Typo.captionRegular)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(selected ? Theme.selectionFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
    }
}

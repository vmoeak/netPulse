import SwiftUI

/// 域名总览: the same hosts the detail pane breaks down per app, but keyed by
/// host — so a CDN several apps share reads as one row carrying their
/// combined traffic, with the apps behind it named underneath.
///
/// Byte counts inherit the estimate `NetworkMonitorEngine` makes when it
/// splits an app's measured rate across its open hosts (see README); the
/// connection counts are exact.
struct DomainsOverviewView: View {
    @ObservedObject var engine: NetworkMonitorEngine

    var body: some View {
        let rollups = engine.domainRollups
        let peak = rollups.first?.totalDownKB ?? 0
        return VStack(spacing: 0) {
            PaneHeader(title: "域名总览",
                       subtitle: "\(rollups.count) 个主机 · 跨全部 App 合并",
                       note: "按累计下载排序")
            columnHeader
            if rollups.isEmpty {
                EmptyPaneMessage(text: "暂无已解析的主机")
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rollups) { rollup in
                            DomainRollupRow(rollup: rollup, peakDownKB: peak)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: PaneWidth.detailMin, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private var columnHeader: some View {
        HStack {
            Text("域名").frame(maxWidth: .infinity, alignment: .leading)
            Text("实时").frame(width: 104, alignment: .trailing)
            Text("累计下载").frame(width: 96, alignment: .trailing)
            Text("累计上传").frame(width: 96, alignment: .trailing)
            Text("连接").frame(width: 56, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Theme.textTertiary)
        .textCase(.uppercase)
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
        .overlay(Rectangle().fill(Theme.hairlineLight).frame(height: 0.5), alignment: .bottom)
    }
}

private struct DomainRollupRow: View {
    let rollup: DomainRollup
    let peakDownKB: Double

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(rollup.host)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(appsLabel).font(.system(size: 10)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("↓ \(Format.rate(rollup.rateDownKBps))")
                .frame(width: 104, alignment: .trailing)
                .foregroundStyle(Color(hex: 0x4A4A4F))
            Text(Format.size(rollup.totalDownKB))
                .frame(width: 96, alignment: .trailing)
                .foregroundStyle(Theme.textPrimary)
            Text(Format.size(rollup.totalUpKB))
                .frame(width: 96, alignment: .trailing)
                .foregroundStyle(Theme.textSecondary)
            Text("\(rollup.connectionCount)")
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 11.5))
        .monospacedDigit()
        .padding(.horizontal, 22)
        .padding(.vertical, 7)
        .background(
            GeometryReader { geo in
                Rectangle()
                    .fill(Theme.accentBlue.opacity(0.07))
                    .frame(width: geo.size.width * min(1, rollup.totalDownKB / max(peakDownKB, 1)))
            }
        )
    }

    /// Naming two apps and counting the rest keeps the row one line wide on a
    /// host like a CDN that a dozen apps share.
    private var appsLabel: String {
        let names = rollup.appNames
        switch names.count {
        case 0: return rollup.kind
        case 1, 2: return names.joined(separator: "、")
        default: return "\(names[0])、\(names[1]) 等 \(names.count) 个 App"
        }
    }
}

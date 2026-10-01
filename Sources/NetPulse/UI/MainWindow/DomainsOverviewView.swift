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
        return VStack(spacing: 0) {
            PaneHeader(title: "域名总览",
                       subtitle: "\(rollups.count) 个主机 · 跨全部 App 合并 · \(engine.range.label)",
                       note: "按累计下载排序")
            columnHeader
            if rollups.isEmpty {
                EmptyPaneMessage(text: "暂无已解析的主机")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rollups) { rollup in
                            DomainRollupRow(rollup: rollup)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: PaneWidth.detailMin - 10, maxWidth: .infinity, maxHeight: .infinity)
        .contentCard()
        .paneDivider()
    }

    private var columnHeader: some View {
        HStack {
            Text("域名").frame(maxWidth: .infinity, alignment: .leading)
            Text("实时").frame(width: 104, alignment: .trailing)
            Text("累计下载").frame(width: 96, alignment: .trailing)
            Text("累计上传").frame(width: 96, alignment: .trailing)
            Text("连接").frame(width: 56, alignment: .trailing)
        }
        .font(Typo.caption)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: 28)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)
    }
}

private struct DomainRollupRow: View {
    let rollup: DomainRollup

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(rollup.host)
                    .font(Typo.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(appsLabel).font(Typo.captionRegular).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RateText(Format.rate(rollup.rateDownKBps), font: Typo.body, color: Theme.textPrimary)
                .frame(width: 104, alignment: .trailing)
            RateText(Format.size(rollup.totalDownKB), font: Typo.body, color: Theme.textPrimary)
                .frame(width: 96, alignment: .trailing)
            RateText(Format.size(rollup.totalUpKB), font: Typo.body, color: Theme.textPrimary)
                .frame(width: 96, alignment: .trailing)
            Text("\(rollup.connectionCount)")
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(Theme.textSecondary)
        }
        .font(Typo.body)
        .monospacedDigit()
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: 40)
        .overlay(Rectangle().fill(Theme.hairlineLight).frame(height: 0.5).padding(.leading, Theme.contentPadding), alignment: .bottom)
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

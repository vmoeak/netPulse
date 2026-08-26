import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Right pane: header with pause/export actions, 4 stat tiles, the 60s
/// throughput chart, and the domain breakdown table — matches lines
/// 197-278 of the design.
struct AppDetailView: View {
    @ObservedObject var engine: NetworkMonitorEngine

    var body: some View {
        Group {
            if let app = engine.selectedApp {
                VStack(spacing: 0) {
                    header(app)
                    statGrid(app)
                    throughputSection(app)
                    domainSection(app)
                }
            } else {
                VStack {
                    Spacer()
                    Text("选择左侧的 App 查看详情").foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
            }
        }
        // 460 is what the domain table's fixed columns plus their padding
        // actually occupy; below it the right-hand columns get cut off.
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private func header(_ app: AppUsage) -> some View {
        HStack(spacing: 12) {
            IconBadge(badge: app.badge, size: 26, cornerRadius: 7, fontSize: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(app.bundleID).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button(app.isPaused ? "恢复该 App" : "暂停该 App") {
                engine.togglePause(appID: app.id)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 11).padding(.vertical, 4)
            .background(Color.black.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button("导出报告") { exportReport(app) }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(Theme.accentBlue)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)
    }

    private func statGrid(_ app: AppUsage) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 1), count: 4)
        return LazyVGrid(columns: cols, spacing: 1) {
            StatTile(label: "实时下载", value: Format.rate(app.rateDownKBps), valueColor: Theme.accentBlue)
            StatTile(label: "实时上传", value: Format.rate(app.rateUpKBps), valueColor: Theme.upOrangeText)
            StatTile(label: "累计下载 · \(engine.range.label)", value: Format.size(app.totalDownKB[engine.range] ?? 0))
            StatTile(label: "累计上传 · \(engine.range.label)", value: Format.size(app.totalUpKB[engine.range] ?? 0))
        }
        .background(Theme.hairline)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)
    }

    private func throughputSection(_ app: AppUsage) -> some View {
        let peak = max(app.downHistory.max() ?? 0, app.upHistory.max() ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("近 60 秒吞吐")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
                Spacer()
                HStack(spacing: 14) {
                    legend(color: Theme.accentBlue, label: "下载")
                    legend(color: Theme.upOrange, label: "上传")
                    Text("峰值 \(Format.rate(peak))").monospacedDigit()
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)
            }
            ZStack {
                LinearGradient(colors: [Color(hex: 0xF7F9FC), .white], startPoint: .top, endPoint: .bottom)
                SparklineArea(values: app.downHistory).fill(Theme.accentBlue.opacity(0.13))
                Sparkline(values: app.downHistory).stroke(Theme.accentBlue, lineWidth: 1.8)
                Sparkline(values: app.upHistory).stroke(Theme.upOrange, lineWidth: 1.5)
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline, lineWidth: 0.5))
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 10)
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func domainSection(_ app: AppUsage) -> some View {
        let maxTotalDown = app.domains.map(\.totalDownKB).max() ?? 1
        return VStack(spacing: 0) {
            HStack {
                Text("域名明细 · \(app.domains.count) 个主机")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(.uppercase)
                Spacer()
                Text("按\(engine.sortMode.label)排序").font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.top, 8).padding(.bottom, 6)

            HStack {
                Text("域名").frame(maxWidth: .infinity, alignment: .leading)
                Text("实时").frame(width: 120, alignment: .trailing)
                Text("累计下载").frame(width: 110, alignment: .trailing)
                Text("累计上传").frame(width: 100, alignment: .trailing)
                Text("连接").frame(width: 64, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 10).padding(.bottom, 6)
            .overlay(Rectangle().fill(Theme.hairlineLight).frame(height: 0.5), alignment: .bottom)

            if app.domains.isEmpty {
                Text("暂无活跃连接").font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(.top, 16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(app.domains) { d in
                            DomainRow(domain: d, maxTotalDown: maxTotalDown)
                        }
                    }
                    .padding(.top, 3)
                }
            }
        }
        .padding(.horizontal, 22)
    }

    private func exportReport(_ app: AppUsage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(app.name)-netpulse-report.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var csv = "host,kind,rate_down_kbps,total_down_kb,total_up_kb,connections\n"
        for d in app.domains {
            csv += "\(d.host),\(d.kind),\(d.rateDownKBps),\(d.totalDownKB),\(d.totalUpKB),\(d.connectionCount)\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct DomainRow: View {
    let domain: DomainUsage
    let maxTotalDown: Double

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(domain.host).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(domain.kind).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("↓ \(Format.rate(domain.rateDownKBps))")
                .frame(width: 120, alignment: .trailing)
                .foregroundStyle(Color(hex: 0x4A4A4F))
            Text(Format.size(domain.totalDownKB))
                .frame(width: 110, alignment: .trailing)
                .foregroundStyle(Theme.textPrimary)
            Text(Format.size(domain.totalUpKB))
                .frame(width: 100, alignment: .trailing)
                .foregroundStyle(Theme.textSecondary)
            Text("\(domain.connectionCount)")
                .frame(width: 64, alignment: .trailing)
                .foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 11.5))
        .monospacedDigit()
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            GeometryReader { geo in
                Rectangle()
                    .fill(Theme.accentBlue.opacity(0.07))
                    .frame(width: geo.size.width * min(1, domain.totalDownKB / max(maxTotalDown, 1)))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

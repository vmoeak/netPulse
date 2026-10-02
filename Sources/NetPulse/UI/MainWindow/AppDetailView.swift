import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Right pane: header with pause/export actions, 4 stat tiles, the 60s
/// throughput chart, and the domain breakdown table — matches lines
/// 197-278 of the design.
struct AppDetailView: View {
    @ObservedObject var engine: NetworkMonitorEngine
    @State private var captureError: String?
    @State private var showUploads = false

    var body: some View {
        Group {
            if let app = engine.selectedApp {
                VStack(spacing: 0) {
                    header(app)
                    statGrid(app)
                    throughputSection(app)
                    tabBar(app)
                    if showUploads {
                        AppUploadsList(inspector: engine.uploads, app: app)
                            .padding(.horizontal, Theme.contentPadding)
                    } else {
                        domainSection(app)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "app.connected.to.app.below.fill")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                    Text("选择左侧的 App 查看详情").font(Typo.rowTitleRegular).foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        // PaneWidth.detailMin is what the domain table's fixed columns plus
        // their padding occupy; below it the right-hand columns get cut off.
        .frame(minWidth: PaneWidth.detailMin - 10, maxWidth: .infinity, maxHeight: .infinity)
        .contentCard()
        .paneDivider()
    }

    private func header(_ app: AppUsage) -> some View {
        HStack(spacing: 10) {
            IconBadge(badge: app.badge, size: 32, cornerRadius: 8, fontSize: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(Typo.title).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(app.bundleID).font(Typo.captionRegular).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            AppInspectSwitch(inspector: engine.uploads, app: app) { on in showUploads = on }
            // Pausing only stops counting; the app's traffic is untouched,
            // which "暂停该 App" did not make clear.
            // A paused app that isn't running still needs a way to resume.
            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    if app.isLive || app.isPaused {
                        Button {
                            engine.togglePause(appID: app.id)
                        } label: {
                            Label(app.isPaused ? "恢复统计" : "暂停统计",
                                  systemImage: app.isPaused ? "play.fill" : "pause.fill")
                        }
                        .glassButton()
                    }

                    Button {
                        exportReport(app)
                    } label: {
                        Label("导出报告", systemImage: "square.and.arrow.up")
                    }
                    .glassButton()
                }
                .font(Typo.bodyMedium)
                .foregroundStyle(Theme.textPrimary)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: Theme.headerHeight)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)
    }

    private func statGrid(_ app: AppUsage) -> some View {
        HStack(spacing: 0) {
            StatTile(label: "实时下载", value: Format.rate(app.rateDownKBps), valueColor: Theme.accentBlue)
            statDivider
            StatTile(label: "实时上传", value: Format.rate(app.rateUpKBps), valueColor: Theme.upOrangeText)
            statDivider
            StatTile(label: "累计下载 · \(engine.range.label)", value: Format.size(app.totalDownKB[engine.range] ?? 0))
            statDivider
            StatTile(label: "累计上传 · \(engine.range.label)", value: Format.size(app.totalUpKB[engine.range] ?? 0))
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 16)
        .overlay(Rectangle().fill(Theme.hairlineLight).frame(height: 0.5), alignment: .bottom)
    }

    /// 域名明细, or the requests 检查上传内容 caught for this app.
    private func tabBar(_ app: AppUsage) -> some View {
        let count = engine.uploads.uploads(forApp: app.id).count
        return Picker("", selection: $showUploads) {
            Text("域名明细").tag(false)
            Text(count > 0 ? "上传内容 · \(count)" : "上传内容").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 240)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.contentPadding).padding(.bottom, 4)
    }

    private var statDivider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 32).padding(.horizontal, 16)
    }

    private func throughputSection(_ app: AppUsage) -> some View {
        // Apps keep 15 minutes of samples for the list's windows; the chart
        // shows the last minute.
        let down = Array(app.downHistory.suffix(60)), up = Array(app.upHistory.suffix(60))
        let peak = max(down.max() ?? 0, up.max() ?? 0)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("近 60 秒吞吐")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                HStack(spacing: 12) {
                    LegendDot(color: Theme.accentBlue, label: "下载")
                    LegendDot(color: Theme.upOrange, label: "上传")
                    Text("峰值 \(Format.rate(peak))").monospacedDigit().foregroundStyle(Theme.textTertiary)
                }
                .font(Typo.captionRegular)
                .foregroundStyle(Theme.textSecondary)
            }
            ChartCard {
                ZStack {
                    ChartGrid().padding(.vertical, 10)
                    // One scale for both lines, so upload reads against
                    // download instead of each filling the plot on its own;
                    // lifted off the bottom edge so an idle line isn't lost.
                    let scale = peak * 1.15
                    SparklineArea(values: down, verticalPadding: 10, scaleMax: scale)
                        .fill(LinearGradient(colors: [Theme.accentBlue.opacity(0.22), Theme.accentBlue.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom))
                    Sparkline(values: down, verticalPadding: 10, scaleMax: scale)
                        .stroke(Theme.accentBlue, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    Sparkline(values: up, verticalPadding: 10, scaleMax: scale)
                        .stroke(Theme.upOrange, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    if peak == 0 {
                        Text("最近 60 秒无流量").font(Typo.captionRegular).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 2)
                .frame(height: 112)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            }
        }
        .padding(.horizontal, Theme.contentPadding).padding(.top, 16).padding(.bottom, 8)
    }

    private func domainSection(_ app: AppUsage) -> some View {
        let domains = engine.sortedDomains(of: app)
        return VStack(spacing: 0) {
            HStack {
                Text("域名明细 · \(app.domains.count) 个主机")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("按\(engine.sortMode.label)排序").font(Typo.captionRegular).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8).padding(.bottom, 8)

            HStack {
                Text("域名").frame(maxWidth: .infinity, alignment: .leading)
                Text("实时").frame(width: 84, alignment: .trailing)
                    .help("按每条连接实测的字节数，每 3 秒更新")
                // Host totals follow the chosen range, like the tiles above.
                Text("下载 · \(engine.range.label)").frame(width: 80, alignment: .trailing)
                    .help("所选时间范围内经过该主机的流量，与上方累计同一范围")
                Text("上传 · \(engine.range.label)").frame(width: 80, alignment: .trailing)
                    .help("所选时间范围内经过该主机的流量，与上方累计同一范围")
                Text("连接").frame(width: 44, alignment: .trailing)
            }
            .font(Typo.caption)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8).padding(.bottom, 6)
            .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)

            proxyCaptureNote(app)

            let visits = engine.proxyVisits(of: app)
            if app.domains.isEmpty && visits.isEmpty {
                Text(app.isLive ? "暂无活跃连接" : "\(engine.range.label)没有按主机记录的流量").font(Typo.body).foregroundStyle(Theme.textTertiary).padding(.top, 16)
                Spacer()
            } else {
                ScrollView {
                    // Not lazy, and the two lists keyed apart: a host and a
                    // site with the same name shared an id, and a stale host
                    // row was left drawn over the site list.
                    VStack(spacing: 0) {
                        ForEach(domains, id: \.host) { d in
                            DomainRow(domain: d)
                        }
                        if !visits.isEmpty {
                            proxyVisitsHeader(count: visits.count, isProxy: app.isProxy)
                            ForEach(visits.map { ("site:" + $0.host, $0) }, id: \.0) { ProxyVisitRow(visit: $0.1) }
                        }
                    }
                    .padding(.top, 3)
                }
            }
        }
        .padding(.horizontal, Theme.contentPadding - 8)
    }

    /// Through a system proxy an app's hosts read "经本机代理": the site is
    /// known only once the loopback capture is installed. Offered there,
    /// and removable from the same place.
    @ViewBuilder
    private func proxyCaptureNote(_ app: AppUsage) -> some View {
        let viaProxy = app.domains.contains { $0.kind.hasPrefix("经本机代理") || $0.kind == "经系统代理" }
        if viaProxy {
            HStack(spacing: 8) {
                Text(!engine.proxyHostCaptureInstalled ? "走系统代理的流量还没分到网站"
                     : engine.proxyHostCaptureOutdated ? "精确统计服务需要更新"
                     : "走系统代理的连接已按网站精确统计")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                if engine.proxyHostCaptureOutdated {
                    Button("更新…") {
                        let error = engine.installProxyHostCapture()
                        captureError = error == "已取消" ? nil : error
                    }
                    .font(.system(size: 11))
                    .glassButton()
                    .controlSize(.small)
                }
                Button(engine.proxyHostCaptureInstalled ? "关闭精确统计" : "开启精确统计…") {
                    let error = engine.proxyHostCaptureInstalled
                        ? engine.removeProxyHostCapture()
                        : engine.installProxyHostCapture()
                    captureError = error == "已取消" ? nil : error
                }
                .font(.system(size: 11))
                .glassButton()
                .controlSize(.small)
                .help("安装一个开机自启的系统服务，只读取每条连到本机代理的连接的第一句（要访问的网站），需要管理员密码")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            if let captureError {
                Text(captureError).font(.system(size: 11)).foregroundStyle(.red).padding(.horizontal, 10)
            }
        }
    }

    /// The proxy's log names sites but not bytes, so these rows only say
    /// where the app went and how often.
    private func proxyVisitsHeader(count: Int, isProxy: Bool) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(isProxy ? "认不出 App 的代理连接 · \(count) 个网站" : "经代理访问的网站 · \(count) 个")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("来自 Shadowrocket 日志，只有次数没有流量")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            // Its own columns: the table header pinned above belongs to the
            // host rows and doesn't describe these.
            HStack {
                Text("网站").frame(maxWidth: .infinity, alignment: .leading)
                Text("走向").frame(width: 52, alignment: .trailing)
                Text("次数").frame(width: 60, alignment: .trailing)
                Text("最后访问").frame(width: 72, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
        .overlay(Rectangle().fill(Theme.hairlineLight).frame(height: 0.5), alignment: .bottom)
    }

    private func exportReport(_ app: AppUsage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(app.name)-netpulse-report.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var csv = "host,kind,rate_down_kbps,total_down_kb,total_up_kb,connections\n"
        for d in engine.sortedDomains(of: app) {
            let fields = [d.host, d.kind,
                          String(format: "%.2f", d.rateDownKBps),
                          String(format: "%.2f", d.totalDownKB),
                          String(format: "%.2f", d.totalUpKB),
                          String(d.connectionCount)]
            csv += fields.map(Self.csvField).joined(separator: ",") + "\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// RFC 4180 quoting: a kind like "本机 · Foo, Inc." used to split into
    /// two columns.
    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private struct DomainRow: View {
    let domain: DomainUsage

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                // One line, elided in the middle: wrapped, "localhost:50316"
                // read as "localhost:5031" over "6".
                Text(domain.host).font(Typo.bodyMedium).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(domain.host)
                Text(domain.kind).font(Typo.captionRegular).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RateText(Format.rate(domain.rateDownKBps), font: Typo.body, color: Theme.textPrimary)
                .frame(width: 84, alignment: .trailing)
            RateText(Format.size(domain.totalDownKB), font: Typo.body, color: Theme.textPrimary)
                .frame(width: 80, alignment: .trailing)
            RateText(Format.size(domain.totalUpKB), font: Typo.body, color: Theme.textPrimary)
                .frame(width: 80, alignment: .trailing)
            Text("\(domain.connectionCount)")
                .font(Typo.body)
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(Theme.textSecondary)
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .frame(height: 40)
        .overlay(Rectangle().fill(Theme.hairlineLight).frame(height: 0.5), alignment: .bottom)
    }
}

private struct ProxyVisitRow: View {
    let visit: ProxyVisit

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(visit.host).font(Typo.bodyMedium).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(visit.host)
                Text(visit.rule.isEmpty ? " " : "规则 \(visit.rule)").font(Typo.captionRegular).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(visit.policy == "DIRECT" ? "直连" : visit.policy == "PROXY" ? "代理" : visit.policy)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(visit.policy == "DIRECT" ? Theme.textSecondary : Theme.accentBlue)
                .frame(width: 52, alignment: .trailing)
            Text("\(visit.count) 次").frame(width: 60, alignment: .trailing).foregroundStyle(Theme.textSecondary)
            Text(visit.lastSeen).frame(width: 72, alignment: .trailing).foregroundStyle(Theme.textSecondary)
        }
        .font(Typo.body)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .frame(height: 40)
    }
}

import SwiftUI

/// Middle column: search + sort toggle, column header, and the scrollable
/// app rows with trend sparklines — matches lines 154-195 of the design.
struct AppListView: View {
    @ObservedObject var engine: NetworkMonitorEngine

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            columnHeader
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(engine.filteredApps) { app in
                        AppRow(app: app, selected: app.id == engine.selectedAppID, sortMode: engine.sortMode,
                               range: engine.range, window: engine.rateWindow)
                            .contentShape(Rectangle())
                            .onTapGesture { engine.select(appID: app.id) }
                    }
                    idleToggle
                }
                // Rows slide to their new places instead of jumping.
                .animation(.easeInOut(duration: 0.35), value: engine.filteredApps.map(\.id))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        // Was a hard 472; flexes now so the window can narrow (see PaneWidth).
        .frame(minWidth: PaneWidth.listMin,
               idealWidth: PaneWidth.listIdeal,
               maxWidth: PaneWidth.listMax)
        .background(Theme.paneBackground)
        .overlay(Rectangle().fill(Theme.hairline).frame(width: 0.5), alignment: .trailing)
    }

    private var toolbar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    TextField("搜索 App", text: $engine.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 11)
                .frame(height: 28)
                .glassSurface(in: Capsule(), interactive: true)
                .frame(maxWidth: .infinity)

                // The system segmented control: on macOS 26 it is drawn in
                // Liquid Glass, with the selection sliding between segments.
                Picker("", selection: $engine.sortMode) {
                    Text("实时速率").tag(SortMode.rate)
                    Text("累计流量").tag(SortMode.total)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                if engine.sortMode == .rate {
                    Picker("", selection: $engine.rateWindow) {
                        ForEach(RateWindow.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .help("按这段时间内的平均速率排序")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    @ViewBuilder private var idleToggle: some View {
        let hidden = engine.hiddenIdleCount
        if hidden > 0 || engine.showIdleApps {
            Button(engine.showIdleApps ? "隐藏从未产生流量的进程" : "显示 \(hidden) 个从未产生流量的进程") {
                engine.showIdleApps.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .padding(.vertical, 10)
        }
    }

    private var columnHeader: some View {
        HStack {
            Text("应用程序").frame(maxWidth: .infinity, alignment: .leading)
            Text("趋势").frame(width: 76, alignment: .trailing)
            Text(rateHeader(down: true)).frame(width: 84, alignment: .trailing)
            Text(rateHeader(down: false)).frame(width: 84, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Theme.textSecondary)
        .textCase(.uppercase)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .overlay(Rectangle().fill(Theme.hairlineLight).frame(height: 0.5), alignment: .bottom)
    }

    private func rateHeader(down: Bool) -> String {
        switch (engine.sortMode, engine.rateWindow) {
        case (.total, _): return down ? "累计下载" : "累计上传"
        case (.rate, .live): return down ? "下载速率" : "上传速率"
        case (.rate, _): return down ? "平均下载" : "平均上传"
        }
    }
}

private struct AppRow: View {
    let app: AppUsage
    let selected: Bool
    let sortMode: SortMode
    let range: TimeRange
    let window: RateWindow

    /// 实时 shows this second's rate; a longer window shows its average,
    /// which is what the list is ranked by.
    private var shownDown: Double { window == .live ? app.rateDownKBps : app.windowDownKBps }
    private var shownUp: Double { window == .live ? app.rateUpKBps : app.windowUpKBps }

    var body: some View {
        HStack(spacing: 0) {
            IconBadge(badge: app.badge)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                if sortMode == .rate && app.windowShare > 0 {
                    // Share of all apps' traffic over the window: bar lengths
                    // compare at a glance where numbers have to be read.
                    HStack(spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.fillStrong)
                                Capsule().fill(Theme.accentBlue.opacity(0.75))
                                    .frame(width: max(2, geo.size.width * app.windowShare))
                            }
                        }
                        .frame(width: 70, height: 4)
                        Text(app.windowShare < 0.01 ? "<1%" : "\(Int((app.windowShare * 100).rounded()))%")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(height: 13)
                } else {
                    Text(app.meta).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Sparkline(values: Array(app.downHistory.suffix(24)))
                    .stroke(Theme.accentBlue, lineWidth: 1.4)
                Sparkline(values: Array(app.upHistory.suffix(24)))
                    .stroke(Theme.upOrange, lineWidth: 1.2)
            }
            .frame(width: 68, height: 24)
            .frame(width: 76, alignment: .trailing)

            Text(sortMode == .rate ? Format.rate(shownDown) : Format.size(app.totalDownKB[range] ?? 0))
                .frame(width: 84, alignment: .trailing)
                .foregroundStyle(Theme.accentBlue)
            Text(sortMode == .rate ? Format.rate(shownUp) : Format.size(app.totalUpKB[range] ?? 0))
                .frame(width: 84, alignment: .trailing)
                .foregroundStyle(Theme.upOrangeText)
        }
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .padding(7)
        .background(selected ? Theme.accentBlue.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .stroke(Theme.accentBlue.opacity(selected ? 0.28 : 0), lineWidth: 0.5)
        }
        .opacity(app.isPaused ? 0.5 : 1)
    }
}

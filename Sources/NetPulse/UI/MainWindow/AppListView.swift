import SwiftUI

/// Middle column: search + sort toggle, column header, and the scrollable
/// app rows with trend sparklines — matches lines 154-195 of the design.
struct AppListView: View {
    @ObservedObject var engine: NetworkMonitorEngine

    var body: some View {
        let trendScale = engine.trendScaleMax
        VStack(spacing: 0) {
            toolbar
            if engine.sortMode == .rate {
                TrafficStackChart(layers: engine.stackLayers(), window: engine.rateWindow)
            }
            columnHeader
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(engine.filteredApps) { app in
                        AppRow(app: app, selected: app.id == engine.selectedAppID, sortMode: engine.sortMode,
                               range: engine.range, window: engine.rateWindow, trendScale: trendScale)
                            .contentShape(Rectangle())
                            .onTapGesture { engine.select(appID: app.id) }
                    }
                    idleToggle
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        // Was a hard 472; flexes now so the window can narrow (see PaneWidth).
        .frame(minWidth: PaneWidth.listMin,
               idealWidth: PaneWidth.listIdeal,
               maxWidth: PaneWidth.listMax)
        .background(Theme.paneBackground)
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

                // A glass capsule with the chosen mode lit in the accent:
                // the system segmented control stays flat gray outside a
                // toolbar, even on macOS 26.
                HStack(spacing: 2) {
                    sortSegment("实时速率", .rate)
                    sortSegment("累计流量", .total)
                }
                .padding(3)
                .glassSurface(in: Capsule())
                .fixedSize()

                if engine.sortMode == .rate {
                    Menu {
                        ForEach(RateWindow.allCases) { window in
                            Button(window.label) { engine.rateWindow = window }
                        }
                    } label: {
                        Text(engine.rateWindow.label).font(.system(size: 11.5, weight: .medium))
                    }
                    // A borderless menu on a glass capsule of its own: a
                    // button-styled menu kept the flat gray bezel.
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .glassSurface(in: Capsule(), interactive: true)
                    .help("按这段时间内的平均速率排序")
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private func sortSegment(_ title: String, _ mode: SortMode) -> some View {
        let active = engine.sortMode == mode
        return Text(title)
            .font(.system(size: 11.5, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? Color.white : Theme.textPrimary)
            .padding(.horizontal, 11)
            .frame(height: 22)
            .background(active ? Theme.accentBlue : Color.clear, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { engine.sortMode = mode }
            }
    }

    @ViewBuilder private var idleToggle: some View {
        let hidden = engine.hiddenIdleCount
        if hidden > 0 || engine.showIdleApps {
            let what = engine.sortMode == .rate ? "空闲的 App（低于 1 KB/s）" : "从未产生流量的进程"
            Button(engine.showIdleApps ? "隐藏\(what)" : "显示 \(hidden) 个\(what)") {
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
        // Every rate window is an average, 实时 included (10 s), so the
        // header says so; the sidebar and menu bar show the last second.
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
    /// Shared top of scale for every row's trend line.
    let trendScale: Double

    /// The window's average, which is what the list is ranked by: a row
    /// showing this second's 0 KB/s beside a 19% share read as a bug.
    private var shownDown: Double { app.windowDownKBps }
    private var shownUp: Double { app.windowUpKBps }

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
                Sparkline(values: Array(app.downHistory.suffix(24)), scaleMax: trendScale)
                    .stroke(Theme.accentBlue, lineWidth: 1.4)
                Sparkline(values: Array(app.upHistory.suffix(24)), scaleMax: trendScale)
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

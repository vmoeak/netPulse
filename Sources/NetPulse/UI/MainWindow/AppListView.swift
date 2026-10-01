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
                LazyVStack(spacing: 0) {
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
        .background(Theme.contentSurface)
    }

    private var toolbar: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("搜索 App", text: $engine.searchText)
                        .textFieldStyle(.plain)
                        .font(Typo.body)
                }
                .padding(.horizontal, 10)
                .frame(height: Theme.controlHeight)
                .background(Theme.controlFillDark, in: Capsule())
                .glassSurface(in: Capsule(), interactive: true)
                .frame(maxWidth: .infinity)

                // A glass capsule with the chosen mode raised on a neutral
                // pill, like a macOS 26 segmented control: the system one
                // stays flat gray outside a toolbar, even on macOS 26.
                HStack(spacing: 0) {
                    sortSegment("实时速率", .rate)
                    sortSegment("累计流量", .total)
                }
                .padding(2)
                .frame(height: Theme.controlHeight)
                .background(Theme.controlFillDark, in: Capsule())
                .glassSurface(in: Capsule())
                .fixedSize()

                if engine.sortMode == .rate {
                    Menu {
                        ForEach(RateWindow.allCases) { window in
                            Button(window.label) { engine.rateWindow = window }
                        }
                    } label: {
                        Text(engine.rateWindow.label).font(Typo.bodyMedium)
                    }
                    // A borderless menu on a glass capsule of its own: a
                    // button-styled menu kept the flat gray bezel.
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: Theme.controlHeight)
                    .background(Theme.controlFillDark, in: Capsule())
                    .glassSurface(in: Capsule(), interactive: true)
                    .help("按这段时间内的平均速率排序")
                }
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: Theme.headerHeight)
    }

    private func sortSegment(_ title: String, _ mode: SortMode) -> some View {
        let active = engine.sortMode == mode
        return Text(title)
            .font(Typo.bodyMedium)
            .foregroundStyle(active ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background {
                if active {
                    Capsule()
                        .fill(Theme.segmentFill)
                        .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
                }
            }
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
            .font(Typo.caption)
            .foregroundStyle(Theme.accentBlue)
            .padding(.vertical, 12)
        }
    }

    private var columnHeader: some View {
        HStack {
            Text("应用程序").frame(maxWidth: .infinity, alignment: .leading)
            Text("趋势").frame(width: 64, alignment: .center)
            Text(rateHeader(down: true)).frame(width: 84, alignment: .trailing)
            Text(rateHeader(down: false)).frame(width: 84, alignment: .trailing)
        }
        .font(Typo.caption)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: 28)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)
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
            IconBadge(badge: app.badge, size: 24, cornerRadius: 6, fontSize: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(Typo.rowTitle).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                if sortMode == .rate && app.windowShare > 0 {
                    // Share of all apps' traffic over the window: bar lengths
                    // compare at a glance where numbers have to be read.
                    HStack(spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.07))
                                Capsule().fill(Theme.accentBlue.opacity(0.55))
                                    .frame(width: max(2, geo.size.width * app.windowShare))
                            }
                        }
                        .frame(width: 64, height: 3)
                        Text(app.windowShare < 0.01 ? "<1%" : "\(Int((app.windowShare * 100).rounded()))%")
                            .font(Typo.captionRegular)
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                    .frame(height: 12)
                } else {
                    Text(app.meta).font(Typo.captionRegular).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Sparkline(values: Array(app.downHistory.suffix(24)), scaleMax: trendScale)
                    .stroke(Theme.accentBlue.opacity(0.6), lineWidth: 1.2)
                Sparkline(values: Array(app.upHistory.suffix(24)), scaleMax: trendScale)
                    .stroke(Theme.upOrange.opacity(0.6), lineWidth: 1.2)
            }
            .frame(width: 56, height: 20)
            .frame(width: 64)

            RateText(sortMode == .rate ? Format.rate(shownDown) : Format.size(app.totalDownKB[range] ?? 0),
                     font: Typo.bodyMedium, color: Theme.accentBlue)
                .frame(width: 84, alignment: .trailing)
            RateText(sortMode == .rate ? Format.rate(shownUp) : Format.size(app.totalUpKB[range] ?? 0),
                     font: Typo.bodyMedium, color: Theme.upOrangeText)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(selected ? Theme.selectionFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .opacity(app.isPaused ? 0.5 : 1)
    }
}

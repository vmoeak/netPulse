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
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                TextField("搜索 App", text: $engine.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.black.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity)

            HStack(spacing: 2) {
                sortButton("实时速率", .rate)
                sortButton("累计流量", .total)
            }
            .padding(2)
            .background(Color.black.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 7))

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
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Theme.paneBackground.opacity(0.9))
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)
    }

    private func sortButton(_ title: String, _ mode: SortMode) -> some View {
        let active = engine.sortMode == mode
        return Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(active ? Color.white : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .shadow(color: .black.opacity(active ? 0.18 : 0), radius: 1, y: 1)
            .contentShape(Rectangle())
            .onTapGesture { engine.sortMode = mode }
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
                                Capsule().fill(Color.black.opacity(0.06))
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
        .background(selected ? Theme.accentBlue.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .opacity(app.isPaused ? 0.5 : 1)
    }
}

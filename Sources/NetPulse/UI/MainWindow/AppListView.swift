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
                        AppRow(app: app, selected: app.id == engine.selectedAppID, sortMode: engine.sortMode, range: engine.range)
                            .contentShape(Rectangle())
                            .onTapGesture { engine.select(appID: app.id) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        // Was a hard 472. The column widths below need ~390, so let the pane
        // flex between that and its design width instead of forcing the window
        // wider than the screen.
        .frame(minWidth: 392, idealWidth: 472, maxWidth: 560)
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

    private var columnHeader: some View {
        HStack {
            Text("应用程序").frame(maxWidth: .infinity, alignment: .leading)
            Text("趋势").frame(width: 76, alignment: .trailing)
            Text(engine.sortMode == .rate ? "下载速率" : "累计下载").frame(width: 84, alignment: .trailing)
            Text(engine.sortMode == .rate ? "上传速率" : "累计上传").frame(width: 84, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Theme.textSecondary)
        .textCase(.uppercase)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .overlay(Rectangle().fill(Theme.hairlineLight).frame(height: 0.5), alignment: .bottom)
    }
}

private struct AppRow: View {
    let app: AppUsage
    let selected: Bool
    let sortMode: SortMode
    let range: TimeRange

    var body: some View {
        HStack(spacing: 0) {
            IconBadge(badge: app.badge)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(app.meta).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
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

            Text(sortMode == .rate ? Format.rate(app.rateDownKBps) : Format.size(app.totalDownKB[range] ?? 0))
                .frame(width: 84, alignment: .trailing)
                .foregroundStyle(Theme.accentBlue)
            Text(sortMode == .rate ? Format.rate(app.rateUpKBps) : Format.size(app.totalUpKB[range] ?? 0))
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

import SwiftUI

/// 活跃连接: every app↔host pair on the machine in one list, busiest first.
/// The app list's per-app view answers "what is this app talking to"; this
/// one answers "what is this Mac talking to right now", which is why it
/// takes the full width to the right of the sidebar rather than sitting
/// beside a detail pane.
struct ConnectionsView: View {
    @ObservedObject var engine: NetworkMonitorEngine

    var body: some View {
        let rows = engine.connectionRows
        return VStack(spacing: 0) {
            PaneHeader(title: "活跃连接",
                       subtitle: "\(rows.count) 个连接目标 · \(engine.connectionCount) 条连接",
                       note: "按实时速率排序")
            columnHeader
            if rows.isEmpty {
                EmptyPaneMessage(text: "暂无活跃连接")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            ConnectionRowView(row: row)
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
            Text("应用程序").frame(maxWidth: .infinity, alignment: .leading)
            Text("远端主机").frame(maxWidth: .infinity, alignment: .leading)
            Text("实时").frame(width: 110, alignment: .trailing)
            Text("连接").frame(width: 56, alignment: .trailing)
        }
        .font(Typo.caption)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: 28)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)
    }
}

private struct ConnectionRowView: View {
    let row: ConnectionRow

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                IconBadge(badge: row.badge, size: 20, cornerRadius: 5, fontSize: 9)
                Text(row.appName)
                    .font(Typo.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.host)
                    .font(Typo.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.kind).font(Typo.captionRegular).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RateText(Format.rate(row.rateDownKBps), font: Typo.body, color: Theme.textPrimary)
                .frame(width: 110, alignment: .trailing)
            Text("\(row.connectionCount)")
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(Theme.textSecondary)
        }
        .font(Typo.body)
        .monospacedDigit()
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: 40)
        .overlay(Rectangle().fill(Theme.hairlineLight).frame(height: 0.5).padding(.leading, Theme.contentPadding), alignment: .bottom)
    }
}

/// Shared chrome for the two full-width panes, matching the 52pt header the
/// detail pane uses so switching sidebar sections doesn't shift the layout.
struct PaneHeader: View {
    let title: String
    let subtitle: String
    let note: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Typo.title).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(Typo.captionRegular).foregroundStyle(Theme.textSecondary).monospacedDigit()
            }
            Spacer()
            Text(note).font(Typo.captionRegular).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.contentPadding)
        .frame(height: Theme.headerHeight)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)
    }
}

struct EmptyPaneMessage: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text).font(Typo.rowTitleRegular).foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

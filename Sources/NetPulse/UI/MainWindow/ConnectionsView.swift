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
                    LazyVStack(spacing: 1) {
                        ForEach(rows) { row in
                            ConnectionRowView(row: row)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }

    private var columnHeader: some View {
        HStack {
            Text("应用程序").frame(maxWidth: .infinity, alignment: .leading)
            Text("远端主机").frame(maxWidth: .infinity, alignment: .leading)
            Text("实时").frame(width: 110, alignment: .trailing)
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

private struct ConnectionRowView: View {
    let row: ConnectionRow

    var body: some View {
        HStack {
            HStack(spacing: 9) {
                IconBadge(badge: row.badge, size: 22, cornerRadius: 6, fontSize: 9.5)
                Text(row.appName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.host)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.kind).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("↓ \(Format.rate(row.rateDownKBps))")
                .frame(width: 110, alignment: .trailing)
                .foregroundStyle(Color(hex: 0x4A4A4F))
            Text("\(row.connectionCount)")
                .frame(width: 56, alignment: .trailing)
                .foregroundStyle(Theme.textSecondary)
        }
        .font(.system(size: 11.5))
        .monospacedDigit()
        .padding(.horizontal, 22)
        .padding(.vertical, 7)
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
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
        .overlay(Rectangle().fill(Theme.hairline).frame(height: 0.5), alignment: .bottom)
        .padding(.bottom, 8)
    }
}

struct EmptyPaneMessage: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

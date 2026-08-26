import SwiftUI
import AppKit

/// The always-visible menu bar chip: the top app's ▲/▼ rates plus a mini
/// 9-bar history sparkline. Matches the design's menu-bar chip (lines
/// 30-40 of NetPulse.dc.html) — the rest of that mock's top strip (Apple
/// menu, app menu items, Wi-Fi/clock) is macOS's own chrome, not something
/// this app draws.
struct MenuBarExtraLabel: View {
    @ObservedObject var engine: NetworkMonitorEngine

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 1) {
                Text("▲ \(Format.rate(engine.topApp?.rateUpKBps ?? 0))")
                    .foregroundStyle(Color(hex: 0xFFD479))
                Text("▼ \(Format.rate(engine.topApp?.rateDownKBps ?? 0))")
                    .foregroundStyle(Color(hex: 0x7EC8FF))
            }
            .font(.system(size: 9.5))
            .monospacedDigit()

            MiniBars(values: Array((engine.topApp?.downHistory ?? []).suffix(9)))
        }
    }
}

/// The 9-bar mini history strip in the menu bar chip and its popover.
struct MiniBars: View {
    let values: [Double]

    var body: some View {
        let maxV = max(values.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(hex: 0x8FD0FF))
                    .frame(width: 2, height: max(2, CGFloat(v / maxV) * 14))
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}

/// Popover content shown when the menu bar chip is clicked. Matches lines
/// 46-82 of the design: top-app summary card, next-4-apps list, footer
/// with combined totals and a button to bring up the main window.
struct MenuBarPopoverView: View {
    @ObservedObject var engine: NetworkMonitorEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            list
            hairline
            footer
        }
        .frame(width: 340)
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前占用最高")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("实时").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
            if let top = engine.topApp {
                HStack(spacing: 12) {
                    IconBadge(badge: top.badge, size: 38, cornerRadius: 9, fontSize: 15)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(top.name).font(.system(size: 14, weight: .semibold))
                        Text(top.meta).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("▼ \(Format.rate(top.rateDownKBps))").foregroundStyle(Color(hex: 0x7EC8FF))
                        Text("▲ \(Format.rate(top.rateUpKBps))").foregroundStyle(Color(hex: 0xFFD479))
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                }
            } else {
                Text("暂无数据").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    private var list: some View {
        VStack(spacing: 2) {
            ForEach(engine.popoverList) { app in
                HStack(spacing: 10) {
                    IconBadge(badge: app.badge, size: 20, cornerRadius: 5, fontSize: 9)
                    Text(app.name).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Text("▼ \(Format.rate(app.rateDownKBps))")
                        .foregroundStyle(Color(hex: 0x7EC8FF))
                        .frame(width: 74, alignment: .trailing)
                    Text("▲ \(Format.rate(app.rateUpKBps))")
                        .foregroundStyle(Color(hex: 0xFFD479))
                        .frame(width: 74, alignment: .trailing)
                }
                .font(.system(size: 11.5))
                .monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 6)
            }
        }
        .padding(8)
    }

    private var footer: some View {
        HStack {
            Text("全部合计 ▼ \(Format.rate(engine.totalDownKBps))  ▲ \(Format.rate(engine.totalUpKBps))")
            Spacer()
            Button("打开主窗口") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5)
    }
}

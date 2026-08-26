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
            // The menu bar gives about 22pt of height. Two 9.5pt lines plus
            // spacing overflow it and the second one is silently clipped,
            // which is why only the ▲ row used to show — 8.5pt with no
            // spacing is what actually fits two lines, and is the size other
            // network meters use up here.
            VStack(alignment: .trailing, spacing: 0) {
                Text("▲ \(Format.rate(engine.topApp?.rateUpKBps ?? 0))")
                    .foregroundStyle(Color(hex: 0xFFD479))
                Text("▼ \(Format.rate(engine.topApp?.rateDownKBps ?? 0))")
                    .foregroundStyle(Color(hex: 0x7EC8FF))
            }
            .font(.system(size: 8.5))
            .monospacedDigit()
            .frame(height: 20)

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
        .background {
            // The whole card is written white-on-dark, like the design's
            // menu-bar panel. `.ultraThinMaterial` on its own renders *light*
            // in Light Appearance, which left white text on a near-white
            // frosted panel — hence the washed-out look. Tint the material
            // dark so the panel matches what the content assumes, whichever
            // appearance the Mac is in.
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: 0x14141A).opacity(0.86))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        // Keeps the material (and anything semantic inside) on its dark
        // variant even when the system is in Light Appearance.
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("当前占用最高")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                Text("实时").font(.system(size: 11)).foregroundStyle(.white.opacity(0.62))
            }
            if let top = engine.topApp {
                HStack(spacing: 12) {
                    IconBadge(badge: top.badge, size: 38, cornerRadius: 9, fontSize: 15)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(top.name).font(.system(size: 14, weight: .semibold))
                        Text(top.meta).font(.system(size: 11)).foregroundStyle(.white.opacity(0.62))
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
                Text("暂无数据").font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    private var list: some View {
        VStack(spacing: 2) {
            ForEach(engine.popoverList) { app in
                HStack(spacing: 10) {
                    IconBadge(badge: app.badge, size: 20, cornerRadius: 5, fontSize: 9)
                    Text(app.name).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.94))
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
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.14)).frame(height: 0.5)
    }
}

import SwiftUI
import AppKit

/// The always-visible menu bar chip: the whole Mac's ▲/▼ rates plus a mini
/// 9-bar history sparkline. (It used to show only the busiest app's rates,
/// which read as the machine total but undercounted whenever two apps were
/// busy; the popover still leads with the busiest app.) Matches the design's menu-bar chip (lines
/// 30-40 of NetPulse.dc.html) — the rest of that mock's top strip (Apple
/// menu, app menu items, Wi-Fi/clock) is macOS's own chrome, not something
/// this app draws.
struct MenuBarExtraLabel: View {
    @ObservedObject var engine: NetworkMonitorEngine

    // MenuBarExtra's label keeps only its first Text or Image and drops the
    // rest of any stack, so on a real Mac the chip showed the ▲ line alone —
    // no ▼ line, no bars — however the stack was sized. Rendering the whole
    // chip into one image is the one layout the menu bar keeps intact.
    // It is a template image, so macOS tints it for light and dark menu
    // bars the way it does its own status items.
    var body: some View {
        Image(nsImage: chipImage)
    }

    @MainActor private var chipImage: NSImage { Self.chipImage(for: engine) }

    @MainActor static func chipImage(for engine: NetworkMonitorEngine) -> NSImage {
        let renderer = ImageRenderer(content: MenuBarChip(
            upKBps: engine.totalUpKBps,
            downKBps: engine.totalDownKBps,
            history: Array(engine.totalDownHistory.suffix(9))))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 1, height: 1))
        image.isTemplate = true
        return image
    }
}

/// What the chip image is drawn from. Solid black only: as a template
/// image, its alpha is all macOS uses.
private struct MenuBarChip: View {
    let upKBps: Double
    let downKBps: Double
    let history: [Double]

    var body: some View {
        HStack(spacing: 6) {
            // Two 8.5pt lines with no spacing are what fit the menu bar's
            // ~22pt height.
            VStack(alignment: .trailing, spacing: 0) {
                // Download first, like everywhere else in the app.
                Text("▼ \(Format.rate(downKBps))")
                Text("▲ \(Format.rate(upKBps))")
            }
            .font(.system(size: 8.5, weight: .medium))
            .monospacedDigit()
            .fixedSize()
            MiniBars(values: history, color: .black)
        }
        .foregroundStyle(.black)
        .frame(height: 20)
        .padding(.horizontal, 1)
    }
}

/// The 9-bar mini history strip in the menu bar chip and its popover.
struct MiniBars: View {
    let values: [Double]
    var color: Color = Color(hex: 0x8FD0FF)

    var body: some View {
        let maxV = max(values.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
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
            recentTop
            hairline
            footer
        }
        // 360 rather than the design's 340: with two fixed rate columns,
        // 340 left names like QQPCMgrDaemon cut off.
        .frame(width: 360)
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
                Text(RateWindow.live.label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.62))
            }
            if let top = engine.popoverTop.first {
                HStack(spacing: 12) {
                    IconBadge(badge: top.app.badge, size: 38, cornerRadius: 9, fontSize: 15)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(top.app.name).font(.system(size: 14, weight: .semibold))
                            .lineLimit(1).truncationMode(.middle).help(top.app.name)
                        Text(top.app.meta).font(.system(size: 11)).foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("▼ \(Format.rate(top.downKBps))").foregroundStyle(Color(hex: 0x7EC8FF))
                        Text("▲ \(Format.rate(top.upKBps))").foregroundStyle(Color(hex: 0xFFD479))
                    }
                    .fixedSize()
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
            // Apps under 1 KB/s are left out rather than listed at ▼0 ▲0.
            ForEach(engine.popoverTop.dropFirst(), id: \.app.id) { entry in
                HStack(spacing: 10) {
                    IconBadge(badge: entry.app.badge, size: 20, cornerRadius: 5, fontSize: 9)
                    Text(entry.app.name).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1).truncationMode(.middle).help(entry.app.name)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    Text("▼ \(Format.rate(entry.downKBps))")
                        .foregroundStyle(Color(hex: 0x7EC8FF))
                        .frame(width: 74, alignment: .trailing)
                    Text("▲ \(Format.rate(entry.upKBps))")
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

    /// Who used the most over the last five minutes, which the live list
    /// above can't answer.
    private var recentTop: some View {
        let top = engine.topApps(over: .fiveMinutes, count: 3)
        return VStack(alignment: .leading, spacing: 6) {
            Text("近 5 分钟占用最多")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            if top.isEmpty {
                Text("这段时间没有明显流量").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5))
            }
            ForEach(Array(top.enumerated()), id: \.element.app.id) { index, entry in
                HStack(spacing: 8) {
                    Text("\(index + 1)").foregroundStyle(.white.opacity(0.5)).frame(width: 12)
                    IconBadge(badge: entry.app.badge, size: 18, cornerRadius: 5, fontSize: 8)
                    Text(entry.app.name).foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1).truncationMode(.middle).help(entry.app.name)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    Text("▼ \(Format.rate(entry.downKBps))")
                        .foregroundStyle(Color(hex: 0x7EC8FF))
                        .frame(width: 74, alignment: .trailing)
                    Text("▲ \(Format.rate(entry.upKBps))")
                        .foregroundStyle(Color(hex: 0xFFD479))
                        .frame(width: 74, alignment: .trailing)
                }
                .font(.system(size: 11.5))
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text("全部合计 ▼ \(Format.rate(engine.totalDownKBps))  ▲ \(Format.rate(engine.totalUpKBps))")
            Spacer()
            Button("打开主窗口") { MainWindowOpener.open(using: openWindow) }
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

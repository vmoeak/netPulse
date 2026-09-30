import AppKit
import SwiftUI

/// Drives the real UI through the checks a person would otherwise click
/// through, and saves what each step looked like as PNGs. Runs when
/// `NETPULSE_SELFTEST_SNAPSHOTS=<dir>` is set alongside
/// `NETPULSE_SELFTEST_SECONDS`, so it needs no accessibility or
/// screen-control permission: the app acts on itself through the same code
/// paths its buttons use and draws its own windows into images.
///
/// The timeline assumes the CI smoke test's traffic: a download that runs
/// from about 5 s to 15 s after launch.
@MainActor
enum UISelfTest {
    static func run(engine: NetworkMonitorEngine, seconds: Double, outputDir: URL) async -> [String: Any] {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let start = Date()
        func waitUntil(_ t: Double) async {
            let remaining = t - Date().timeIntervalSince(start)
            if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
        }
        var result: [String: Any] = [:]
        var snapshots: [String] = []
        func snap(_ name: String) {
            snapshots += snapshotMainWindows(named: name, into: outputDir)
        }

        // (b) 打开主窗口 twice must leave one main window, not three.
        await waitUntil(3)
        let before = MainWindowOpener.shownMainWindows.count
        if let open = engine.openMainWindowAction {
            open()
            await waitUntil(4)
            open()
            await waitUntil(5)
            result["b"] = ["windowsBefore": before,
                           "windowsAfter": MainWindowOpener.shownMainWindows.count] as [String: Any]
        } else {
            result["b"] = ["error": "main window never appeared, so there was no open-window action"] as [String: Any]
        }
        snap("b-after-open-twice")

        // (c) curl's hosts show in 活跃连接 while it downloads, then leave.
        engine.section = .connections
        await waitUntil(11)
        let during = curlRows(engine)
        snap("c1-connections-during-download")
        await waitUntil(max(20, seconds - 8))
        let after = curlRows(engine)
        snap("c2-connections-after-download")
        result["c"] = ["curlRowsDuring": during, "curlRowsAfter": after] as [String: Any]

        // (d) Under 累计流量, apps that haven't run this launch are listed.
        engine.sortMode = .total
        engine.section = .apps
        await waitUntil(max(21, seconds - 7))
        result["d"] = ["notRunning": engine.listedApps.filter { !$0.isLive }.map(\.name)] as [String: Any]
        snap("d-apps-by-total")

        // (e) The detail pane's host table follows the sort toggle.
        if let busiest = engine.apps.filter(\.isLive).max(by: { $0.domains.count < $1.domains.count }) {
            engine.select(appID: busiest.id)
            engine.sortMode = .rate
            await waitUntil(max(22, seconds - 6))
            let byRate = engine.selectedApp.map { engine.sortedDomains(of: $0).map(\.host) } ?? []
            snap("e1-detail-by-rate")
            engine.sortMode = .total
            await waitUntil(max(23, seconds - 5))
            let byTotal = engine.selectedApp.map { engine.sortedDomains(of: $0).map(\.host) } ?? []
            snap("e2-detail-by-total")
            result["e"] = ["app": busiest.name, "rateOrder": byRate, "totalOrder": byTotal] as [String: Any]
        }

        // (a) The menu bar chip: the image the label draws, and the status
        // bar item as the menu bar actually shows it.
        let chip = MenuBarExtraLabel.chipImage(for: engine)
        if writePNG(chip, to: outputDir.appendingPathComponent("a-chip.png")) { snapshots.append("a-chip.png") }
        result["a"] = ["chipWidth": Double(chip.size.width), "chipHeight": Double(chip.size.height)] as [String: Any]
        for (i, window) in NSApp.windows.enumerated()
        where String(describing: type(of: window)).contains("StatusBar") {
            let name = "a-menubar-\(i).png"
            if snapshot(window, to: outputDir.appendingPathComponent(name)) { snapshots.append(name) }
        }

        await waitUntil(seconds)
        result["snapshots"] = snapshots
        return result
    }

    private static func curlRows(_ engine: NetworkMonitorEngine) -> [String] {
        engine.connectionRows.filter { $0.appID == "proc.curl" }.map(\.host)
    }

    private static func snapshotMainWindows(named name: String, into dir: URL) -> [String] {
        var written: [String] = []
        for (i, window) in MainWindowOpener.shownMainWindows.enumerated() {
            let file = i == 0 ? "\(name).png" : "\(name)-\(i).png"
            if snapshot(window, to: dir.appendingPathComponent(file)) { written.append(file) }
        }
        return written
    }

    private static func snapshot(_ window: NSWindow, to url: URL) -> Bool {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    private static func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}

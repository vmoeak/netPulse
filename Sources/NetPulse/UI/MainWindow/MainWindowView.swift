import AppKit
import SwiftUI

/// Single source of truth for how narrow each pane may get. The window's
/// floor is their sum, so the two must not drift apart — a window narrower
/// than this lays the panes out at these widths anyway and overflows,
/// clipping the sidebar and the detail pane instead of compressing them.
enum PaneWidth {
    static let sidebar: CGFloat = 216
    static let listMin: CGFloat = 360
    static let listIdeal: CGFloat = 472
    static let listMax: CGFloat = 560
    static let detailMin: CGFloat = 400
    static let windowMin = sidebar + listMin + detailMin
    static let windowMinHeight: CGFloat = 600
}

/// Root of the main window. 所有 App keeps the design's three-column
/// 216 / 472 / flexible layout; the other two sidebar sections are
/// machine-wide lists with no per-app detail to show, so they take the
/// whole width to the right of the sidebar.
struct MainWindowView: View {
    @ObservedObject var engine: NetworkMonitorEngine

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(engine: engine)
            switch engine.section {
            case .apps:
                AppListView(engine: engine)
                AppDetailView(engine: engine)
            case .connections:
                ConnectionsView(engine: engine)
            case .domains:
                DomainsOverviewView(engine: engine)
            }
        }
        .frame(idealWidth: 1280, idealHeight: 820)
        .background(WindowFloor(size: NSSize(width: PaneWidth.windowMin,
                                             height: PaneWidth.windowMinHeight)))
    }
}

/// Enforces the window's minimum on the NSWindow itself.
///
/// `.windowResizability(.contentMinSize)` alone was not enough: it governs
/// what a *resize* may do, while the frame macOS restores from a previous
/// launch is applied as-is. A window saved by an older build therefore came
/// back narrower than the layout needs and clipped both side panes. Setting
/// `contentMinSize` fixes the floor for good, and the one-time grow brings
/// an already-too-small restored window up to it.
private struct WindowFloor: NSViewRepresentable {
    let size: NSSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view has no window until it is in the hierarchy.
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.contentMinSize = size
        let content = window.contentRect(forFrameRect: window.frame).size
        guard content.width < size.width || content.height < size.height else { return }
        let grown = NSSize(width: max(content.width, size.width),
                           height: max(content.height, size.height))
        window.setContentSize(grown)
    }
}

import SwiftUI

/// Root of the main window. 所有 App keeps the design's three-column
/// 216 / 472 / flexible layout; the other two sidebar sections are
/// machine-wide lists with no per-app detail to show, so they take the
/// whole width to the right of the sidebar.
///
/// No `minWidth` is imposed here — each pane declares what it actually
/// needs and the window enforces the sum (see `windowResizability` in
/// `NetPulseApp`). Hard-coding one here made the window claim a width it
/// could then be resized below, which clipped the sidebar and detail pane
/// rather than shrinking them.
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
        .frame(idealWidth: 1280, minHeight: 620, idealHeight: 820)
    }
}

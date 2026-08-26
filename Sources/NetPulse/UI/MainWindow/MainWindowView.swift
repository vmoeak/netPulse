import SwiftUI

/// Root of the main window: sidebar | app list | detail, matching the
/// 216 / 472 / flexible three-column layout at lines 84-279 of the design.
struct MainWindowView: View {
    @ObservedObject var engine: NetworkMonitorEngine

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(engine: engine)
            AppListView(engine: engine)
            AppDetailView(engine: engine)
        }
        .frame(minWidth: 1000, idealWidth: 1200, minHeight: 640, idealHeight: 800)
    }
}

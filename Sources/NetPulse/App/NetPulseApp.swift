import SwiftUI

@main
struct NetPulseApp: App {
    @StateObject private var engine = NetworkMonitorEngine()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView(engine: engine)
        }

        // The menu bar chip is always present once the app launches, so
        // monitoring starts from its label view rather than waiting on the
        // main window (which may never be opened) or the popover content
        // (which SwiftUI may not build until first click).
        MenuBarExtra {
            MenuBarPopoverView(engine: engine)
        } label: {
            MenuBarExtraLabel(engine: engine)
                .task { engine.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

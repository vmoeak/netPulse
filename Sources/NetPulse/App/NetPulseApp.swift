import SwiftUI

@main
struct NetPulseApp: App {
    @StateObject private var engine = NetworkMonitorEngine()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView(engine: engine)
        }
        .defaultSize(width: 1280, height: 820)
        // WindowGroup's default resizability lets the window be dragged below
        // what its content needs, which clips the panes on both sides instead
        // of compressing them. contentMinSize makes the floor the panes
        // declare the window's floor too.
        .windowResizability(.contentMinSize)

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

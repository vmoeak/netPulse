import AppKit
import SwiftUI

/// Brings up the main window, shared by the popover's 打开主窗口 button and
/// the UI self-test (which is how that button's behavior gets checked
/// without anyone clicking it).
@MainActor
enum MainWindowOpener {
    static func open(using openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)
        // openWindow on a WindowGroup always adds a window, so each click
        // used to stack another copy. Bring back the existing one when there
        // is (SwiftUI names them "main-AppWindow-N").
        if let existing = shownMainWindows.first {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    /// A closed window can linger in NSApp.windows without its content, so
    /// only a shown or minimized one counts.
    static var shownMainWindows: [NSWindow] {
        NSApp.windows.filter {
            $0.identifier?.rawValue.hasPrefix("main") == true && ($0.isVisible || $0.isMiniaturized)
        }
    }
}

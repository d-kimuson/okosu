import SwiftUI

/// Shell: menu-bar-only app (no dock icon, LSUIElement).
/// Recording/transcription engine comes later (see docs/HANDOVER.md).
@main
struct OkosuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No windows; UI lives in the menu-bar popover owned by AppDelegate.
        Settings {
            EmptyView()
        }
    }
}

import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Toggle the transcription popover (default: Cmd+M, user-remappable).
    static let togglePopover = Self("togglePopover", default: .init(.m, modifiers: .command))
}

/// Owns the menu-bar item, the popover, the global hotkey, and the engine store.
/// whisper-stream は起動時に立ち上げっぱなしにし、モデルを掴んだままにする
/// （初回 ANE コンパイル約30秒をバックグラウンドで消化＝ウォームアップ）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover = NSPopover()
    private var settingsWindow: NSWindow?
    private let store = TranscriptionStore()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Okosu")
        item.button?.action = #selector(togglePopover(_:))
        item.button?.target = self
        self.statusItem = item

        popover.contentSize = NSSize(width: 360, height: 480)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView().environmentObject(store))

        KeyboardShortcuts.onKeyUp(for: .togglePopover) { [weak self] in
            self?.togglePopover(nil)
        }

        // エンジン失敗は無言にしない: エラーになったらポップオーバーを開いて再試行導線を見せる。
        store.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                if case .error = state, !self.popover.isShown {
                    self.togglePopover(nil)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openSettings)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.openSettings() }
            .store(in: &cancellables)

        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    /// 設定ウィンドウを開く（前面になければ作る）。LSUIElement のため自前管理。
    @objc func openSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // contentViewController 任せにするとフィッティングサイズがゼロになり
        // 空ウィンドウになるため、明示 rect で作る。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingController(rootView: SettingsView())
        window.contentViewController = hosting
        // hosting ビューの frame は初期ゼロのため、fittingSize を窓に反映させる。
        hosting.view.layout()
        var contentSize = hosting.view.fittingSize
        if contentSize.width < 1 { contentSize.width = 440 }
        if contentSize.height < 1 { contentSize.height = 560 }
        window.setContentSize(contentSize)
        window.title = "Okosu の設定"
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

import AppKit
import Foundation

/// クリップボードへのコピー。`TranscriptionStore` から型長制限のため分離した自由関数。
func copyToPasteboard(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(string, forType: .string)
}

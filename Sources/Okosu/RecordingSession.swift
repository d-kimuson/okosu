import Foundation

/// 1録音セッション＝開始→停止の区間。
/// 確定チャンクは `text` に機械的な改行区切りで追記される。
struct RecordingSession: Equatable, Identifiable {
    var id = UUID()
    var startedAt = Date()
    var endedAt: Date?
    var text = ""

    /// 受付中（まだ停止されていない）。
    var isLive: Bool { endedAt == nil }
}

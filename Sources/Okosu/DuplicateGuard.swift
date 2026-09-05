import Foundation

/// VAD キャプチャの重なりによる二重確定を抑止する。
///
/// whisper-stream（VAD モード）は発話検出のたび直前 `--length` ミリ秒の窓を
/// 切り出して推論するため、連続キャプチャで同一発話が複数ブロック化する。
/// 同一内容＋キャプチャ時刻の重なりをもって重複と判定する。
/// 意図的な言い直し（時刻が重ならない）は通す。
struct DuplicateGuard {
    private var last: TranscriptBlock?

    /// 重複なら true。非重複の場合のみ内部状態を更新する。
    mutating func isDuplicate(_ block: TranscriptBlock) -> Bool {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        let isSameText = { (last: TranscriptBlock) in
            text == last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let last, isSameText(last), block.t0ms < last.t1ms {
            return true
        }
        last = block
        return false
    }

    mutating func reset() {
        last = nil
    }
}

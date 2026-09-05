import Foundation

/// VAD キャプチャの重なりによる二重確定を抑止する。
///
/// whisper-stream（VAD モード）は発話検出のたび直前 `--length` ミリ秒の窓を
/// 切り出して推論するため、連続キャプチャで同一発話が複数ブロック化する。
/// 窓ずれでデコードが揺れる（句点の有無・語尾変化）ため、完全一致だけでなく
/// 正規化＋境界アンカーで判定する。
/// 判定はキャプチャ時刻の重なりを前提にする。時刻が重ならない反復は
/// 意図的な言い直しとして常に通す（dictation として正しい）。
struct DuplicateGuard {
    /// 比較から除く文字（空白＋文末記号）。本文自体は削らない。
    private static let ignorable: Set<Character> = [
        " ", "　", "\t", "\n", "\r",
        "。", "、", "，", "．", ".", ",", "!", "！", "?", "？",
        "…", "‥", "・", "〜", "～", "-", "ー",
        "\"", "\"", "'", "'", "「", "」", "『", "』", "（", "）", "(", ")"
    ]

    /// アンカーとみなす最小文字数。
    private static let minAnchor = 4
    /// 照合する文脈長（末尾何文字を見るか）。
    private static let contextLength = 200

    /// 直近に追記した内容（正規化済み・末尾のみ保持）。
    private var context = ""
    /// 直近に追記したブロックの窓終端。
    private var lastEnd = -1

    /// ブロックを処理する。nil＝抑止（追記しない）、非 nil＝追記すべきテキスト。
    mutating func process(_ block: TranscriptBlock) -> String? {
        let stripped = Self.strip(block.text)
        guard !stripped.isEmpty else { return nil }

        // 窓が重ならない＝別音声。常に通す（意図的反復の保存）。
        guard block.t0ms < lastEnd else {
            pushContext(stripped, end: block.t1ms)
            return block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tail = String(context.suffix(Self.contextLength))
        // 新規分が文脈末尾に含まれる＝読み直し。捨てる。
        if tail.contains(stripped) {
            return nil
        }
        // 境界アンカー：文脈末尾＝新規先頭の最大重なり。以降だけ追記する。
        if let anchor = Self.anchorLength(tail: tail, head: stripped), anchor < stripped.count {
            let suffix = Self.dropSignificant(block.text, count: anchor)
            guard !Self.strip(suffix).isEmpty else { return nil }
            pushContext(Self.strip(suffix), end: block.t1ms)
            return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        pushContext(stripped, end: block.t1ms)
        return block.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func reset() {
        context = ""
        lastEnd = -1
    }

    // MARK: - private

    private mutating func pushContext(_ stripped: String, end: Int) {
        context = String((context + stripped).suffix(Self.contextLength))
        lastEnd = max(lastEnd, end)
    }

    static func strip(_ text: String) -> String {
        text.filter { !ignorable.contains($0) }
    }

    /// `tail` の末尾＝`head` の先頭の最大重なり長。`minAnchor` 未満は nil。
    static func anchorLength(tail: String, head: String) -> Int? {
        let maxK = min(tail.count, head.count)
        guard maxK >= minAnchor else { return nil }
        var best: Int?
        for length in minAnchor...maxK where tail.hasSuffix(head.prefix(length)) {
            best = length
        }
        return best
    }

    /// 先頭から有意文字（除去対象外）を `count` 個落とした残り。
    static func dropSignificant(_ text: String, count: Int) -> String {
        var dropped = 0
        var index = text.startIndex
        while index < text.endIndex, dropped < count {
            if !ignorable.contains(text[index]) {
                dropped += 1
            }
            index = text.index(after: index)
        }
        return String(text[index...])
    }
}

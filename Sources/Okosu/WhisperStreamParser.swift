import Foundation

/// whisper-stream VAD モード（`--step 0`）の標準出力をパースする。
///
/// VAD モードでは発話区切りごとに以下のブロックが確定単位として出る
/// （whisper.cpp examples/stream/stream.cpp の `use_vad` 経路）。
/// 暫定表示の行上書きは非 VAD モードの話なので、ここでは扱わない。
///
/// ```
/// ### Transcription 3 START | t0 = 12000 ms | t1 = 18500 ms
///
/// [00:00:12.000 --> 00:00:18.500]  こんにちは
///
/// ### Transcription 3 END
/// ```
///
/// 使い方はチャンク駆動: `Process` の stdout ハンドラから来た Data を
/// `feed(_:)` に渡すと、ブロック完成ごとに `onBlock` が呼ばれる。
/// 行境界で分割されていないチャンクにも対応するため、内部で残余を保持する。
struct TranscriptSegment: Equatable {
    /// `[00:00:12.000 --> 00:00:18.500]` 部分。なければ nil。
    var timestamp: String?
    var text: String
}

struct TranscriptBlock: Equatable, Identifiable {
    var id: Int
    var t0ms: Int
    var t1ms: Int
    var segments: [TranscriptSegment]

    /// セグメントを結合した確定テキスト。
    var text: String {
        segments.map(\.text).joined(separator: "\n")
    }
}

final class WhisperStreamParser {
    /// ブロック完成時のコールバック（Runner が購読する）。
    var onBlock: ((TranscriptBlock) -> Void)?
    /// エンジン準備完了 (`[Start speaking]` 行) のコールバック。
    /// モデルロード・ANE コンパイル完了後に1回出る。受付中表示の条件にする。
    var onReady: (() -> Void)?

    private var pending = ""
    private var currentID: Int?
    private var currentT0 = 0
    private var currentT1 = 0
    private var currentSegments: [TranscriptSegment] = []

    /// 未パースの生テキスト（デバッグ・ログ用）。
    private(set) var droppedLineCount = 0

    func feed(_ chunk: String) {
        pending += chunk
        // 改行で割って、末尾の不完全行は次回に持ち越す。
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        for line in lines {
            feedLine(line)
        }
    }

    /// 残余バッファを強制フラッシュする（プロセス終了時に呼ぶ）。
    func flush() {
        if !pending.isEmpty {
            let rest = pending
            pending = ""
            feedLine(rest)
        }
        // ブロック内で終わった場合は破棄（不完全な発話として捨てる）。
        currentID = nil
        currentSegments = []
    }

    private func feedLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        if line == "[Start speaking]" {
            onReady?()
            return
        }

        if let start = Self.parseStart(line) {
            // 前ブロックが END なしで残っていたら破棄して新規開始。
            currentID = start.id
            currentT0 = start.t0ms
            currentT1 = start.t1ms
            currentSegments = []
            return
        }

        if let endID = Self.parseEnd(line) {
            guard let id = currentID, id == endID else {
                // 対応する START がない END は無視。
                droppedLineCount += 1
                return
            }
            let block = TranscriptBlock(id: id, t0ms: currentT0, t1ms: currentT1, segments: currentSegments)
            currentID = nil
            currentSegments = []
            onBlock?(block)
            return
        }

        guard currentID != nil else {
            // ブロック外の行（`[Start speaking]`、空行、起動ログ等）は無視。
            return
        }
        guard !line.isEmpty else { return }

        if let segment = Self.parseSegment(line) {
            currentSegments.append(segment)
        } else {
            // タイムスタンプなしの素テキスト行も拾う（将来の形式ゆれへの耐性）。
            currentSegments.append(TranscriptSegment(timestamp: nil, text: line))
        }
    }

    // MARK: - 行パーサ

    /// START 行のヘッダ（END との対応付け・時刻表示用）。
    struct BlockHeader {
        var id: Int
        var t0ms: Int
        var t1ms: Int
    }

    // swiftlint:disable:next force_try
    private static let startRegex = try! NSRegularExpression(
        // リテラル固定のため失敗し得ない。static 初期化で毎回 do/catch しないための force。
        pattern: #"^### Transcription (\d+) START \| t0 = (\d+) ms \| t1 = (\d+) ms"#
    )
    // swiftlint:disable:next force_try
    private static let endRegex = try! NSRegularExpression(
        pattern: #"^### Transcription (\d+) END"#
    )

    private static func capturedInts(_ regex: NSRegularExpression, in line: String) -> [Int] {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return [] }
        return (1..<match.numberOfRanges).compactMap { groupIndex in
            let nsRange = match.range(at: groupIndex)
            guard nsRange.location != NSNotFound, let swiftRange = Range(nsRange, in: line) else { return nil }
            return Int(line[swiftRange])
        }
    }

    static func parseStart(_ line: String) -> BlockHeader? {
        let numbers = capturedInts(startRegex, in: line)
        guard numbers.count == 3 else { return nil }
        return BlockHeader(id: numbers[0], t0ms: numbers[1], t1ms: numbers[2])
    }

    static func parseEnd(_ line: String) -> Int? {
        capturedInts(endRegex, in: line).first
    }

    static func parseSegment(_ line: String) -> TranscriptSegment? {
        // `[00:00:12.000 --> 00:00:18.500]  本文 [SPEAKER_TURN?]`
        guard line.hasPrefix("[") else { return nil }
        guard let close = line.firstIndex(of: "]") else { return nil }
        let timestamp = String(line[line.index(after: line.startIndex)..<close])
        guard timestamp.contains("-->") else { return nil }
        var text = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("[SPEAKER_TURN]") {
            text = text.replacingOccurrences(of: "[SPEAKER_TURN]", with: "").trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }
        return TranscriptSegment(timestamp: timestamp, text: text)
    }
}

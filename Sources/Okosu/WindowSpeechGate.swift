import Foundation

/// 音声窓に出力すべきか（発話があったか）の純粋判定。
/// 計測の取得は呼び出し側（`MicLevelMonitor`）が行い、ここは合否だけ決める。
/// 判定不能なときは通す（フェイルオープン。文字起こしの欠落より幻覚残存を選ぶ）。
struct WindowSpeechGate {
    /// この RMS 未満だけなら無音とみなす。実機のノイズフロアに合わせて調整する。
    var threshold: Float = 0.01

    /// - `hasData`: 監視が1件でも標本を取れたか。false＝監視失敗→通す。
    /// - `maxRMS`: 窓範囲内の最大 RMS。nil＝範囲内に標本なし→通す。
    func keep(maxRMS: Float?, hasData: Bool) -> Bool {
        guard hasData, let maxRMS else { return true }
        return maxRMS >= threshold
    }

    /// ブロックの論理時刻（エンジン起点からの ms）を時刻範囲に直して判定する。
    /// `levelIn` は範囲内の最大 RMS を返す（`MicLevelMonitor.maxRMS` を渡す）。
    func keep(block: TranscriptBlock, audioStart: Date, levelIn: (Date, Date) -> Float?, hasData: Bool) -> Bool {
        let start = audioStart.addingTimeInterval(Double(block.t0ms) / 1000)
        let end = audioStart.addingTimeInterval(Double(block.t1ms) / 1000)
        return keep(maxRMS: levelIn(start, end), hasData: hasData)
    }
}

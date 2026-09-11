import AVFoundation
import Foundation

/// マイク入力の音量（RMS）を時刻付きで記録する。
///
/// whisper-stream がマイクを握ったまま自前でも入力を開く（macOS では複数
/// クライアント可）。5秒窓のどこに発話があったかを後から照会し、無音窓の
/// 幻覚（無音なのに「ごめん」等が出る）を捨てる材料にする。
/// 監視に失敗しても文字起こしは止めない（`hasData == false` でフェイルオープン）。
struct LevelSample {
    var time: Date
    var rms: Float
}

final class MicLevelMonitor {
    /// エンジン窓との対応付け用に範囲指定で取り出す。範囲外は無視する。
    var margin: TimeInterval = 0.5
    /// 保持する標本の上限（64ms/件換算で約4分。セッションは通常もっと短い）。
    var maxSamples = 3600

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var samples: [LevelSample] = []
    private var started = false

    var hasData: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !samples.isEmpty
    }

    /// 監視を開始する。入力デバイスがなければ何もせず戻る。
    func start() {
        reset()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.record(buffer: buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return
        }
        lock.lock()
        self.engine = engine
        started = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        started = false
        lock.unlock()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    func reset() {
        stop()
        lock.lock()
        samples = []
        lock.unlock()
    }

    /// 窓範囲（±margin）内の最大 RMS。標本がなければ nil。
    func maxRMS(start: Date, end: Date) -> Float? {
        let from = start.addingTimeInterval(-margin)
        let until = end.addingTimeInterval(margin)
        lock.lock()
        defer { lock.unlock() }
        var maxRMS: Float?
        for sample in samples where sample.time >= from && sample.time <= until {
            maxRMS = max(maxRMS ?? 0, sample.rms)
        }
        return maxRMS
    }

    private func record(buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum: Float = 0
        for index in 0..<count {
            let value = channel[index]
            sum += value * value
        }
        let sample = LevelSample(time: Date(), rms: (sum / Float(count)).squareRoot())
        lock.lock()
        samples.append(sample)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        lock.unlock()
    }
}

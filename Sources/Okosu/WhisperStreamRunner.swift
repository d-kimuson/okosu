import Foundation

/// whisper-stream 子プロセスの管理。
///
/// - 起動引数: `--step 0 -l ja`（VAD モード。HANDOVER 参照）＋ .env 既定の窓設定。
/// - stdout を `WhisperStreamParser` に流し、確定ブロックを `onBlock` で通知する。
/// - stderr の末尾を保持し、異常終了時の診断に使う。`Core ML model loaded` の
///   検出で ANE 使用中かどうかを `onANEDetected` で通知する。
/// - 常駐＋掴みっぱなし運用（HANDOVER のウォームアップ方針）: 起動直後の初回 ANE
///   コンパイル約30秒はバックグラウンドで消化される。
final class WhisperStreamRunner {
    var onBlock: ((TranscriptBlock) -> Void)?
    var onANEDetected: ((Bool) -> Void)?
    var onTerminated: ((Int32, String) -> Void)?
    /// 子の `[Start speaking]`（モデルロード完了）。起動成功の条件。
    var onReady: (() -> Void)?

    private var process: Process?
    private let parser = WhisperStreamParser()
    private var stderrTail: [String] = []
    private let stderrTailLimit = 20
    private var aneDetected = false
    private var intentionalStop = false

    var isRunning: Bool { process?.isRunning == true }

    struct Options {
        var language = "ja"
        var threads = 8
        var lengthMs = 8000
        var keepMs = 200
    }

    init() {
        parser.onBlock = { [weak self] block in self?.onBlock?(block) }
        parser.onReady = { [weak self] in self?.onReady?() }
    }

    /// バイナリ解決→起動まで行う。モデルパスは `ModelManager.ensureModel()` 済みを想定。
    func start(binaryPath: String, modelPath: String, options: Options = Options()) throws {
        stop()
        intentionalStop = false
        aneDetected = false
        stderrTail = []

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "-m", modelPath,
            "-l", options.language,
            "-t", String(options.threads),
            "--step", "0",
            "--length", String(options.lengthMs),
            "--keep", String(options.keepMs)
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            self?.parser.feed(text)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            self?.handleStderr(text)
        }

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            self.parser.flush()
            if !self.intentionalStop {
                let tail = self.stderrTail.joined(separator: "\n")
                self.onTerminated?(proc.terminationStatus, tail)
            }
        }

        do {
            try process.run()
        } catch {
            throw WhisperError.launchFailed("whisper-stream の起動に失敗しました: \(error.localizedDescription)")
        }
        self.process = process
    }

    func stop() {
        intentionalStop = true
        parser.flush()
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        process.terminate()
        // 終了猶予 2 秒 → 応じなければ kill。
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.interrupt()
            if process.isRunning {
                // 最終手段: SIGKILL（Process に直接 API がないため kill(2)）。
                kill(process.processIdentifier, SIGKILL)
            }
        }
        self.process = nil
    }

    // MARK: - private

    private func handleStderr(_ text: String) {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            stderrTail.append(trimmed)
            if stderrTail.count > stderrTailLimit {
                stderrTail.removeFirst()
            }
            if !aneDetected, trimmed.contains("Core ML model loaded") {
                aneDetected = true
                onANEDetected?(true)
            }
        }
    }
}

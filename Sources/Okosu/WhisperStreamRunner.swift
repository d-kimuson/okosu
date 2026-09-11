import Foundation

/// whisper-stream を5秒の非重複窓で実行する。
/// 出力処理はプロセスごとの直列キュー、通知は main queue に順序を保って配送する。
final class WhisperStreamRunner {
    var onBlock: ((TranscriptBlock) -> Void)?
    var onANEDetected: ((Bool) -> Void)?
    var onTerminated: ((Int32, String) -> Void)?
    var onReady: (() -> Void)?
    /// finish() による末尾推論・stdout 回収の完了。onBlock より後に通知する。
    var onFinished: ((Int32, String) -> Void)?

    private var process: Process?
    private var activeID: UUID?
    private var finishing = false

    var isRunning: Bool { process?.isRunning == true }

    struct Options {
        var language = "ja"
        var threads = 8
        // step と length を別々に変更させない（ローリング窓への逆戻りを防ぐ）。
        var windowMs = 5000

        func arguments(modelPath: String) -> [String] {
            ["-m", modelPath, "-l", language, "-t", String(threads),
             "--step", String(windowMs), "--length", String(windowMs), "--keep", "0"]
        }
    }

    private enum Event {
        case block(TranscriptBlock)
        case ready
        case ane
        case ended(Int32, String)
    }

    /// バイナリ解決・モデル配置は呼び出し元で完了させる。
    func start(binaryPath: String, modelPath: String, options: Options = Options()) throws {
        stop()
        precondition(options.windowMs > 0)
        let identifier = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = options.arguments(modelPath: modelPath)
        let capture = Capture(windowMs: options.windowMs)
        let emit: (Event) -> Void = { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeID == identifier else { return }
                self.receive(event)
            }
        }
        capture.parser.onBlock = { emit(.block($0)) }
        capture.parser.onReady = { emit(.ready) }
        capture.onANE = { emit(.ane) }
        process.standardOutput = capture.stdout
        process.standardError = capture.stderr
        capture.stdout.fileHandleForReading.readabilityHandler = { handle in
            capture.queue.sync {
                capture.parser.feed(handle.availableData)
            }
        }
        capture.stderr.fileHandleForReading.readabilityHandler = { handle in
            capture.queue.sync {
                capture.readStderr(handle.availableData)
            }
        }
        process.terminationHandler = { proc in
            capture.stdout.fileHandleForReading.readabilityHandler = nil
            capture.stderr.fileHandleForReading.readabilityHandler = nil
            capture.queue.async {
                // 終了通知と最後の readability callback の競合でも、末尾を捨てない。
                capture.parser.feed(capture.stdout.fileHandleForReading.readDataToEndOfFile())
                capture.parser.flush()
                capture.readStderr(capture.stderr.fileHandleForReading.readDataToEndOfFile())
                emit(.ended(proc.terminationStatus, capture.stderrTail))
            }
        }
        activeID = identifier
        finishing = false
        self.process = process
        do {
            try process.run()
        } catch {
            capture.stdout.fileHandleForReading.readabilityHandler = nil
            capture.stderr.fileHandleForReading.readabilityHandler = nil
            activeID = nil
            self.process = nil
            throw WhisperError.launchFailed("whisper-stream の起動に失敗しました: \(error.localizedDescription)")
        }
    }

    /// SDL の Ctrl+C 経路は待機中の短い音声も最後に推論する。UI を止めずに終了を待つ。
    func finish() {
        guard let process, !finishing else { return }
        finishing = true
        if process.isRunning {
            process.interrupt()
            killAfterDeadline(process, seconds: 15)
        }
    }

    /// 起動キャンセル・アプリ終了用。末尾回収が必要な通常停止は finish() を使う。
    func stop() {
        activeID = nil
        finishing = false
        guard let process else { return }
        self.process = nil
        if process.isRunning {
            process.terminate()
            killAfterDeadline(process, seconds: 2)
        }
    }

    private func killAfterDeadline(_ process: Process, seconds: Double) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func receive(_ event: Event) {
        switch event {
        case let .block(block): onBlock?(block)
        case .ready: onReady?()
        case .ane: onANEDetected?(true)
        case let .ended(code, tail):
            process = nil
            activeID = nil
            if finishing {
                finishing = false
                onFinished?(code, tail)
            } else {
                onTerminated?(code, tail)
            }
        }
    }
}

/// 1プロセスの I/O 状態。再起動したエンジンとパーサ・診断ログを共有しない。
private final class Capture {
    let queue = DispatchQueue(label: "okosu.whisper-output")
    let stdout = Pipe()
    let stderr = Pipe()
    let parser: WhisperStreamParser
    var onANE: (() -> Void)?
    private var detectedANE = false
    private var stderrBytes = Data()
    // バイト数で切った診断ログの先頭は UTF-8 の途中でもよい。置換して残りを読めるようにする。
    // swiftlint:disable:next optional_data_string_conversion
    var stderrTail: String { String(decoding: stderrBytes, as: UTF8.self) }

    init(windowMs: Int) {
        parser = WhisperStreamParser(mode: .fixedWindow(milliseconds: windowMs))
    }

    func readStderr(_ data: Data) {
        stderrBytes.append(data)
        if stderrBytes.count > 8192 { stderrBytes = Data(stderrBytes.suffix(8192)) }
        if !detectedANE, stderrTail.contains("Core ML model loaded") {
            detectedANE = true
            onANE?()
        }
    }
}

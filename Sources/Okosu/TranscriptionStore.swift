import AppKit
import AVFoundation
import Combine
import Foundation

/// 画面とエンジンの仲介。録音セッション列を唯一の真実として保持する。
///
/// 1セッション＝開始→停止の区間。確定チャンクはその区間のセッションに追記され、
/// チャンクごとに機械的な改行が入る（文境界の判定はしない）。
///
/// UI に触れるメソッドは @MainActor。Runner コールバック（バックグラウンド）からは
/// `Task { @MainActor in … }` で遷移させる。init は非隔離のままにして
/// AppDelegate（非隔離）から生成できるようにする。
final class TranscriptionStore: ObservableObject {
    enum EngineState: Equatable {
        case idle
        case starting(String)
        case listening
        case error(String)
    }

    @Published private(set) var sessions: [RecordingSession] = []
    @Published private(set) var state: EngineState = .idle
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var usesANE = false

    /// 全セッションを結合した全文（すべてコピー対象）。
    var transcriptText: String {
        sessions.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    var statusText: String {
        switch state {
        case .idle: "停止中"
        case let .starting(message): message
        case .listening: usesANE ? "受付中（ANE）" : "受付中"
        case .error: "エラー"
        }
    }

    var canCopy: Bool { !transcriptText.isEmpty }
    var isListening: Bool { state == .listening }
    /// 起動シーケンス進行中（開始ボタンはこの間押せない）。
    var isBooting: Bool {
        if case .starting = state { return true }
        return false
    }

    private let runner = WhisperStreamRunner()
    private var bootTask: Task<Void, Never>?
    /// stop() で世代を進め、取り残された boot を無効化する。
    private var generation = 0
    /// 想定外終了からの自動再接続カウンタ。受信回復でリセット。
    private var autoRestartCount = 0
    private let maxAutoRestart = 3

    init() {
        runner.onBlock = { [weak self] block in
            Task { @MainActor in self?.append(block) }
        }
        runner.onANEDetected = { [weak self] _ in
            Task { @MainActor in self?.usesANE = true }
        }
        runner.onTerminated = { [weak self] code, tail in
            Task { @MainActor in self?.handleUnexpectedTermination(code: code, tail: tail) }
        }
    }

    /// 録音＋文字起こしを開始する。常駐＋掴みっぱなしで初回 ANE コンパイルを裏で消化する。
    /// 停止→開始の再入可。二重起動は無視する。
    @MainActor func start() {
        guard !isListening, bootTask == nil else { return }
        autoRestartCount = 0
        launchBoot()
    }

    /// boot Task の生成を一元化（手動開始・自動再接続で共有）。
    @MainActor private func launchBoot(delay: Duration = .zero) {
        let gen = generation
        bootTask = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard gen == generation, !Task.isCancelled else { return }
            }
            await boot(generation: gen)
            bootTask = nil
        }
    }

    @MainActor func retry() {
        start()
    }

    /// 録音＋文字起こしを停止する。確定済みテキストは保持する。
    @MainActor func stop() {
        generation += 1
        bootTask?.cancel()
        bootTask = nil
        autoRestartCount = 0
        runner.stop()
        endLiveSession()
        if isListening || isBooting {
            state = .idle
        }
    }

    @MainActor func clear() {
        sessions = []
    }

    @MainActor func updateSession(id: UUID, text: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sessions.remove(at: index)
            return
        }
        sessions[index].text = trimmed
    }

    @MainActor func removeSession(id: UUID) {
        sessions.removeAll { $0.id == id }
    }

    @MainActor func copyToClipboard() {
        copy(string: transcriptText)
    }

    @MainActor func copySession(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        copy(string: session.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func copy(string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: - private

    @MainActor private func boot(generation gen: Int) async {
        state = .starting("マイク確認中…")
        let micGranted = await requestMicrophoneAccess()
        guard gen == generation, !Task.isCancelled else { return }
        guard micGranted else {
            state = .error("マイクへのアクセスが拒否されました。「システム設定 > プライバシーとセキュリティ > マイク」で Okosu を許可してください。")
            return
        }

        state = .starting("バイナリ確認中…")
        let binary: String
        do {
            binary = try WhisperBinary.resolve()
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        state = .starting("モデル確認中…")
        do {
            let paths = try await ModelManager.ensureModel { [weak self] ratio in
                Task { @MainActor in
                    self?.downloadProgress = ratio
                    self?.state = .starting(String(format: "モデルを取得中… %.0f%%", ratio * 100))
                }
            }
            guard gen == generation, !Task.isCancelled else { return }
            usesANE = paths.hasEncoder
            state = .starting("エンジン起動中…（初回は ANE 準備に約30秒）")
            let options = WhisperStreamRunner.Options()
            try runner.start(binaryPath: binary, modelPath: paths.ggml.path, options: options)
            beginLiveSession()
            state = .listening
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    @MainActor private func append(_ block: TranscriptBlock) {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 受信回復＝健全とみなし、自動再接続カウンタをリセットする。
        autoRestartCount = 0
        // 受付中のセッションがなければ作る（想定外の順序への耐性）。
        if sessions.last?.isLive != true {
            sessions.append(RecordingSession())
        }
        // 確定チャンクごとに機械的な改行を入れるだけ。文境界の判定はしない。
        let index = sessions.count - 1
        if sessions[index].text.isEmpty {
            sessions[index].text = text + "\n"
        } else {
            sessions[index].text += text + "\n"
        }
    }

    /// 受付中セッションを開始する（boot 完了時）。
    @MainActor private func beginLiveSession() {
        if sessions.last?.isLive == true { return }
        sessions.append(RecordingSession())
    }

    /// 受付中セッションを締める（停止時・異常終了時）。空セッションは残さない。
    @MainActor private func endLiveSession() {
        guard let last = sessions.last, last.isLive else { return }
        if last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessions.removeLast()
        } else {
            sessions[sessions.count - 1].endedAt = Date()
        }
    }

    @MainActor private func handleUnexpectedTermination(code: Int32, tail: String) {
        // stop() 経由の意図的停止では呼ばれない（Runner が握りつぶす）。
        endLiveSession()
        // 一時的な音声デバイスの hiccup 等に備え、3回まで自動再接続する。
        // 4回目は諦めてエラーを表示する（恒常故障での無限ループ防止）。
        if autoRestartCount < maxAutoRestart {
            autoRestartCount += 1
            state = .starting("whisper-stream が終了したため再接続中… (\(autoRestartCount)/\(maxAutoRestart))")
            launchBoot(delay: .seconds(3))
        } else {
            state = .error(WhisperError.terminatedUnexpectedly(code, tail).localizedDescription)
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

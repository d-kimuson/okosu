import AppKit
import AVFoundation
import Combine
import Darwin
import Foundation

/// 画面とエンジンの仲介。録音セッション列を唯一の真実として保持する。
///
/// 1セッション＝開始→停止の区間。確定チャンクはその区間のセッションに追記され、
/// チャンクごとに機械的な改行が入る（文境界の判定はしない）。
///
/// UI に触れるメソッドは @MainActor。Runner は main queue に順序を保って通知する。
/// init は非隔離のままにして
/// AppDelegate（非隔離）から生成できるようにする。
final class TranscriptionStore: ObservableObject {

    @Published private(set) var sessions: [RecordingSession] = []
    @Published private(set) var state: EngineState = .idle
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var usesANE = false

    var statusText: String { state.statusText(usesANE: usesANE) }

    var isListening: Bool { state == .listening }
    var isFinishing: Bool { state == .finishing }
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
    /// プロセス存続中は保持する二重起動防止ロック (flock は死ねば自動解放)。
    private var instanceLockFD: Int32 = -1
    /// 子の `[Start speaking]` 待ち継続。stop() 時に resume して待機を解く。
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var copyOnFinish = false
    /// 自前のマイク音量監視。エンジンと同じ起点で計測し、無音窓の幻覚を捨てる。
    private let micMonitor = MicLevelMonitor()
    private let speechGate = WindowSpeechGate()
    /// エンジンの音声窓の起点（子プロセス起動≒SDL キャプチャ開始の wall clock）。
    private var audioStartTime: Date?
    /// 無音判定で捨てた窓の数（デバッグ用。UI には出さない）。
    private(set) var silencedWindowDrops = 0

    init() {
        runner.onBlock = { [weak self] block in
            MainActor.assumeIsolated { self?.append(block) }
        }
        runner.onANEDetected = { [weak self] _ in
            MainActor.assumeIsolated { self?.usesANE = true }
        }
        runner.onTerminated = { [weak self] code, tail in
            MainActor.assumeIsolated { self?.handleUnexpectedTermination(code: code, tail: tail) }
        }
        runner.onReady = { [weak self] in
            MainActor.assumeIsolated { self?.handleEngineReady() }
        }
        runner.onFinished = { [weak self] code, tail in
            MainActor.assumeIsolated { self?.handleFinished(code: code, tail: tail) }
        }
    }

    /// 録音＋文字起こしを開始する。常駐＋掴みっぱなしで初回 ANE コンパイルを裏で消化する。
    /// 停止→開始の再入可。二重起動は無視する。
    @MainActor func start() {
        guard !isListening, !isFinishing, bootTask == nil else { return }
        autoRestartCount = 0
        launchBoot()
    }

    /// boot Task の生成を一元化（手動開始・自動再接続で共有）。
    @MainActor private func launchBoot(delay: Duration = .zero) {
        // 取り残された待機があれば先に解く（古い待機は世代不一致で return する）。
        bootTask?.cancel()
        clearReadyContinuation()
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

    /// 通常停止は最後の短い音声を回収してからセッションを締める。
    @MainActor func stop() {
        guard !isFinishing else { return }
        if isListening {
            state = .finishing
            micMonitor.stop()
            runner.finish()
            return
        }
        shutdown()
    }

    /// 起動キャンセル・アプリ終了用の即時停止。
    @MainActor func shutdown() {
        copyOnFinish = false
        generation += 1
        bootTask?.cancel()
        bootTask = nil
        autoRestartCount = 0
        // readiness 待ちで止まっている boot があれば解く。
        clearReadyContinuation()
        micMonitor.stop()
        runner.stop()
        endLiveSession()
        if isListening || isBooting || isFinishing {
            state = .idle
        }
    }

    // MARK: - private

    @MainActor private func boot(generation gen: Int) async {
        guard acquireInstanceLock() else {
            state = .error("Okosu は既に起動しています。2重起動はできません。")
            return
        }
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
            try await startEngine(binary: binary, generation: gen)
            guard gen == generation, !Task.isCancelled else { return }
            beginLiveSession()
            state = .listening
        } catch {
            guard gen == generation, !Task.isCancelled else { return }
            // ここに来るのは起動前の恒常要因のみ（マイク拒否・バイナリ欠落等）。
            // 起動後の死亡は termination ハンドラ経由。リトライしても直らない
            // ためそのままエラー表示する。
            state = .error(error.localizedDescription)
        }
    }

    /// エンジン起動＋ readiness 待ち。spawn 成功では受付中にせず、
    /// 子の `[Start speaking]`（モデルロード完了）をもって起動成功とする。
    /// 待機前に死んだら termination ハンドラ経由で再接続へ回る。
    @MainActor private func startEngine(binary: String, generation gen: Int) async throws {
        state = .starting("エンジン起動中…（初回は ANE 準備に約30秒）")
        let options = WhisperStreamRunner.Options()
        let modelPath = ModelManager.ggmlURL.path
        // 子の SDL キャプチャは起動直後に始まる。自前計測も同じ起点で始める。
        audioStartTime = Date()
        micMonitor.start()
        do {
            try runner.start(binaryPath: binary, modelPath: modelPath, options: options)
        } catch {
            micMonitor.stop()
            audioStartTime = nil
            throw error
        }
        state = .starting("準備中…（モデルを読み込んでいます）")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            readyContinuation = continuation
        }
        readyContinuation = nil
        guard gen == generation, !Task.isCancelled else { return }
        guard runner.isRunning else {
            throw WhisperError.terminatedUnexpectedly(-1, "whisper-stream が起動前に終了しました")
        }
    }

    private func clearReadyContinuation() {
        readyContinuation?.resume(returning: ())
        readyContinuation = nil
    }

    /// 子の readiness 通知。待機中のみ受領する。
    @MainActor private func handleEngineReady() {
        readyContinuation?.resume(returning: ())
        readyContinuation = nil
    }

    /// 二重起動防止ロックを取得する。既取得済みなら true。
    @MainActor private func acquireInstanceLock() -> Bool {
        if instanceLockFD >= 0 { return true }
        let url = ModelManager.supportDirectory.appendingPathComponent("okosu.lock")
        try? FileManager.default.createDirectory(at: ModelManager.supportDirectory, withIntermediateDirectories: true)
        let fileDesc = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fileDesc >= 0 else { return false }
        // 同一プロセス内の別 fd でも EWOULDBLOCK になり得るため、先に短絡済み。
        guard flock(fileDesc, LOCK_EX | LOCK_NB) == 0 else {
            close(fileDesc)
            return false
        }
        instanceLockFD = fileDesc
        return true
    }

    @MainActor private func append(_ block: TranscriptBlock) {
        guard isListening || isFinishing else { return }
        autoRestartCount = 0
        // 別々の音声窓なので文字列の重複排除はしない。意図的な反復も残す。
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 窓全体が無音ならモデルの幻覚として捨てる。判定不能時は通す。
        if let start = audioStartTime {
            let keep = speechGate.keep(block: block, audioStart: start,
                                       levelIn: micMonitor.maxRMS, hasData: micMonitor.hasData)
            guard keep else {
                silencedWindowDrops += 1
                return
            }
        }
        // 受付中のセッションがなければ作る（想定外の順序への耐性）。
        if sessions.last?.isLive != true {
            sessions.append(RecordingSession())
        }
        // 確定チャンクごとに機械的な改行を入れるだけ。文境界の判定はしない。
        let index = sessions.count - 1
        sessions[index].text += text + "\n"
    }

    /// 受付中セッションを開始する（boot 完了時）。

    @MainActor private func handleUnexpectedTermination(code: Int32, tail: String) {
        // stop() 経由の意図的停止では呼ばれない（Runner が握りつぶす）。
        // readiness 待ち中の死亡もここで拾う（唯一の再接続経路）。
        failEngine(message: WhisperError.terminatedUnexpectedly(code, tail).localizedDescription)
    }

    /// 子の異常終了時の共通経路。一時要因に備え3回まで自動再接続する。
    /// 4回目は諦めてエラーを表示する（恒常故障での無限ループ防止）。
    @MainActor private func failEngine(message: String) {
        endLiveSession()
        // 古い待機 boot を無効化してから再接続する。
        generation += 1
        if autoRestartCount < maxAutoRestart {
            autoRestartCount += 1
            state = .starting("whisper-stream が終了したため再接続中… (\(autoRestartCount)/\(maxAutoRestart))")
            launchBoot(delay: .seconds(3))
        } else {
            state = .error(message)
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

/// セッション列の操作。型長制限のため class 本体から分離（同ファイルのため private のまま）。
extension TranscriptionStore {
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

    /// 末尾回収後にコピーする（ホットキー終了用）。
    @MainActor func finishLiveSessionAndCopy() {
        guard isListening else { return }
        copyOnFinish = true
        stop()
    }

    @MainActor func copySession(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        copyToPasteboard(session.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor private func handleFinished(code: Int32, tail: String) {
        guard isFinishing else { return }
        if code == 0, copyOnFinish, let live = sessions.last, live.isLive {
            let text = live.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { copyToPasteboard(text) }
        }
        copyOnFinish = false
        endLiveSession()
        state = code == 0 ? .idle : .error("最後の音声の処理に失敗しました。確定済みの内容は保持しています。\n" + tail)
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
}

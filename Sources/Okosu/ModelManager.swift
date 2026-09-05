import Foundation

/// モデルファイルの配置管理。
///
/// - 配置先: `~/Library/Application Support/Okosu/`（HANDOVER 記載の通り git 管理外・初回 DL）。
/// - GGML（約0.5GB）: なければ Hugging Face から取得する。
/// - Core ML encoder（約1.2GB の `.mlmodelc` ディレクトリ）: 単一ファイル DL 不可のため
///   自動取得しない。PoC の `tools/coreml-encoder/README.md` 手順で作り、同ディレクトリに
///   置けば whisper-stream が自動検出して ANE を使う。なければ Metal/CPU フォールバック。
enum ModelManager {
    /// Kotoba-Whisper v2.0 GGML（q5_0）。PoC の stream.sh と同一。
    static let ggmlFileName = "ggml-kotoba-whisper-v2.0-q5_0.bin"
    /// whisper.cpp の派生規則と同一: 拡張子＋量子化サフィックスを落として `-encoder.mlmodelc`。
    static let encoderDirName = "ggml-kotoba-whisper-v2.0-encoder.mlmodelc"

    private static let ggmlBaseURL = "https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0-ggml/resolve/main/"
    static let ggmlDownloadURL = URL(string: ggmlBaseURL + ggmlFileName)!

    struct ModelPaths {
        var ggml: URL
        /// encoder が同ディレクトリにあれば true（＝ANE 使用見込み）。
        var hasEncoder: Bool
    }

    static var supportDirectory: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Library/Application Support/Okosu", isDirectory: true)
    }

    static var ggmlURL: URL { supportDirectory.appendingPathComponent(ggmlFileName) }
    static var encoderURL: URL { supportDirectory.appendingPathComponent(encoderDirName) }

    /// GGML モデルの存在を保証する。なければ DL する（進捗は `progress` に通知）。
    /// 戻り値で ANE encoder の有無も返す。
    static func ensureModel(progress: @escaping (Double) -> Void = { _ in }) async throws -> ModelPaths {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: ggmlURL.path) {
            try await downloadGGML(progress: progress)
        }

        var isDir: ObjCBool = false
        let hasEncoder = FileManager.default.fileExists(atPath: encoderURL.path, isDirectory: &isDir) && isDir.boolValue
        return ModelPaths(ggml: ggmlURL, hasEncoder: hasEncoder)
    }

    static var encoderSetupHint: String {
        "ANE encoder がありません（Metal フォールバック）。高速化するには PoC の " +
            "tools/coreml-encoder/README.md 手順で作り、\(encoderURL.path) に配置してください。"
    }

    // MARK: - private

    private static func downloadGGML(progress: @escaping (Double) -> Void) async throws {
        let tmpURL = ggmlURL.appendingPathExtension("downloading")
        try? FileManager.default.removeItem(at: tmpURL)

        let delegate = DownloadDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let tempFile = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: ggmlDownloadURL).resume()
        }
        try FileManager.default.moveItem(at: tempFile, to: tmpURL)
        try FileManager.default.moveItem(at: tmpURL, to: ggmlURL)
        progress(1.0)
    }

    /// 進捗付きダウンロード用の最小 delegate。完了は continuation で返す。
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        var continuation: CheckedContinuation<URL, Error>?
        private let progress: (Double) -> Void
        private var lastReported = -1.0
        private var finished = false

        init(progress: @escaping (Double) -> Void) {
            self.progress = progress
        }

        func urlSession(
            _: URLSession,
            downloadTask _: URLSessionDownloadTask,
            didWriteData _: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let ratio = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            if ratio - lastReported >= 0.01 {
                lastReported = ratio
                progress(min(ratio, 1.0))
            }
        }

        func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard !finished else { return }
            finished = true
            continuation?.resume(returning: location)
            continuation = nil
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
            guard !finished else { return }
            if let error {
                finished = true
                continuation?.resume(throwing: error)
                continuation = nil
            }
        }
    }
}

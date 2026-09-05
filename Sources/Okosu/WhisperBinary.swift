import Foundation

/// whisper-stream 実行ファイルの解決。
///
/// 将来はアプリバンドルに同梱するが、MVP ではシステム側の既存バイナリを使う。
/// 解決順: アプリ Resources → 環境変数 `OKOSU_WHISPER_STREAM` → 定番パス →
/// `PATH` 探索（nix profile / Homebrew を含む）。
enum WhisperBinary {
    static let environmentOverride = "OKOSU_WHISPER_STREAM"

    static func resolve() throws -> String {
        // 1. 将来の同梱先（今は未同梱。あれば最優先）。
        let bundled = Bundle.main.path(forResource: "whisper-stream", ofType: nil)
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        // 2. 環境変数での明示指定（開発時の切り替え用）。
        let overridePath = ProcessInfo.processInfo.environment[environmentOverride] ?? ""
        if !overridePath.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: overridePath) else {
                throw WhisperError.binaryNotFound("環境変数 \(environmentOverride) の先が実行できません: \(overridePath)")
            }
            return overridePath
        }

        // 3. 定番インストール先。
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/whisper-stream",
            "/usr/local/bin/whisper-stream",
            home + "/.nix-profile/bin/whisper-stream",
            "/nix/var/nix/profiles/default/bin/whisper-stream",
            "/run/current-system/sw/bin/whisper-stream"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // 4. PATH 探索。
        if let found = searchPATH(), FileManager.default.isExecutableFile(atPath: found) {
            return found
        }

        throw WhisperError.binaryNotFound(
            "whisper-stream が見つかりません。whisper.cpp をインストールしてください "
                + "（例: brew install whisper-cpp / nix profile）。開発中は \(environmentOverride) でパス指定も可。"
        )
    }

    private static func searchPATH() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["whisper-stream"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }
}

enum WhisperError: LocalizedError {
    case binaryNotFound(String)
    case modelMissing(String)
    case launchFailed(String)
    case terminatedUnexpectedly(Int32, String)

    var errorDescription: String? {
        switch self {
        case let .binaryNotFound(message): message
        case let .modelMissing(message): message
        case let .launchFailed(message): message
        case let .terminatedUnexpectedly(code, tail): "whisper-stream が異常終了しました（code=\(code)）: \(tail)"
        }
    }
}

import Foundation

/// エンジンの状態。`TranscriptionStore` から型長制限のため分離した表示用 enum。
enum EngineState: Equatable {
    case idle
    case starting(String)
    case listening
    case finishing
    case error(String)

    func statusText(usesANE: Bool) -> String {
        switch self {
        case .idle: "停止中"
        case let .starting(message): message
        case .listening: usesANE ? "受付中・5秒単位（ANE）" : "受付中・5秒単位"
        case .finishing: "最後の音声を処理中…"
        case .error: "エラー"
        }
    }
}

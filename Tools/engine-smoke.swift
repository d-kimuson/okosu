// 実エンジンの短い窓の停止確認。SDL_AUDIODRIVER=dummy でマイクを使わず実行する。
// 引数: whisper-stream のパス、モデルのパス
import Foundation

@main enum EngineSmoke {
    static func main() throws {
        let runner = WhisperStreamRunner()
        var finished = false
        var success = false
        var blocks = 0
        runner.onReady = {
            print("READY: 1秒の短い窓で停止します")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { runner.finish() }
        }
        runner.onBlock = { _ in blocks += 1 }
        runner.onFinished = { code, tail in
            print("FINISHED: status=\(code), blocks=\(blocks)")
            if code != 0 { print(tail) }
            success = code == 0 && blocks > 0
            finished = true
        }
        runner.onTerminated = { code, tail in
            print("FAILED: \(code)\n\(tail)")
            finished = true
        }
        try runner.start(binaryPath: CommandLine.arguments[1], modelPath: CommandLine.arguments[2])
        let deadline = Date().addingTimeInterval(90)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        runner.stop()
        guard success else { exit(1) }
        print("ALL PASS: 実エンジンが5秒未満の音声を停止時に推論して正常終了")
    }
}

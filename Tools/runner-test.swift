// 子プロセスとの統合テスト（マイク・モデルなし）。Tools/test.sh で実行。
import Foundation

@main enum RunnerTests {
    static func main() throws {
        let runner = WhisperStreamRunner()
        var blocks: [String] = []
        var ready = false
        var finished = false
        var failure: String?
        runner.onReady = { ready = true }
        runner.onBlock = { block in
            if !ready { failure = "readiness より前に出力された" }
            blocks.append(block.text)
            if blocks.count == 2 { runner.finish() }
        }
        runner.onTerminated = { code, tail in
            failure = "予期しない終了: \(code) \(tail)"
            finished = true
        }
        runner.onFinished = { code, _ in
            if code != 0 { failure = "停止失敗: \(code)" }
            if blocks != ["同じ言葉。", "同じ言葉。", "最後の短い発話"] {
                failure = "停止完了前の末尾回収・順序が不正: \(blocks)"
            }
            finished = true
        }
        try runner.start(binaryPath: CommandLine.arguments[1], modelPath: "/unused")
        let deadline = Date().addingTimeInterval(10)
        while !finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        runner.stop()
        guard finished, failure == nil else {
            print("NG: \(failure ?? "停止がタイムアウト")")
            exit(1)
        }
        // 起動直後のキャンセル→再開始。古い callback / パーサを引き継がない。
        blocks = []
        ready = false
        finished = false
        try runner.start(binaryPath: CommandLine.arguments[1], modelPath: "/unused")
        runner.stop()
        try runner.start(binaryPath: CommandLine.arguments[1], modelPath: "/unused")
        let restartDeadline = Date().addingTimeInterval(10)
        while !finished, Date() < restartDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        runner.stop()
        guard finished, failure == nil else {
            print("NG: \(failure ?? "再開始がタイムアウト")")
            exit(1)
        }
        print("ALL PASS: UTF-8断片化・同文反復・SIGINT末尾回収・完了通知の順序・キャンセル再開始")
    }
}

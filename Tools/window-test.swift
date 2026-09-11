// 固定長窓の stdout 契約。Tools/test.sh で実行。
import Foundation

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "ok" : "NG"): \(label)")
    if !condition { failures += 1 }
}

let erase = "\u{1b}[2K\r"
func output(_ text: String) -> String {
    erase + String(repeating: " ", count: 100) + erase + text + "\n"
}

@main enum WindowTests {
    static func main() {
        let parser = WhisperStreamParser(mode: .fixedWindow(milliseconds: 5000))
        var blocks: [TranscriptBlock] = []
        var ready = 0
        parser.onBlock = { blocks.append($0) }
        parser.onReady = { ready += 1 }
        let fixture = "startup log\n[Start speaking]\n" + output("こんにちは。")
            + output("今日はいい天気です。") + output("今日はいい天気です。") + output("  ")
        // 日本語の UTF-8 と ANSI シーケンスの途中を含む、1バイトごとの受信。
        for byte in fixture.utf8 { parser.feed(Data([byte])) }
        check(ready == 1, "readiness は1回")
        check(blocks.map(\.text) == ["こんにちは。", "今日はいい天気です。", "今日はいい天気です。", ""],
              "制御文字・ログを除去し、別音声の同文と空窓を保持")
        check(blocks.map(\.t0ms) == [0, 5000, 10000, 15000], "窓の論理時刻は重ならない")
        parser.feed(Data((erase + " 最後の短い発話").utf8))
        check(blocks.count == 4, "改行までは確定しない")
        parser.flush()
        check(blocks.last?.text == "最後の短い発話", "正常終了時の改行なし末尾も回収")
        parser.flush()
        check(blocks.count == 5, "flush で二重追記しない")
        let options = WhisperStreamRunner.Options()
        let args = options.arguments(modelPath: "/tmp/model.bin")
        check(args.contains("5000"), "既定は5秒窓")
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        check(value("--step") == "5000" && value("--length") == "5000" && value("--keep") == "0",
              "同じ音声を再デコードしない起動引数")
        if failures > 0 { exit(1) }
        print("ALL PASS")
    }
}

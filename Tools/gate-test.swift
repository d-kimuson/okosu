// WindowSpeechGate の単体テスト（マイク不要）。Tools/test.sh で実行。
import Foundation

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print("\(condition ? "ok" : "NG"): \(label)")
    if !condition { failures += 1 }
}

@main enum GateTests {
    static func main() {
        let gate = WindowSpeechGate()
        check(gate.keep(maxRMS: 0.0001, hasData: true) == false, "無音窓は捨てる")
        check(gate.keep(maxRMS: 0.05, hasData: true) == true, "発話窓は通す")
        check(gate.keep(maxRMS: 0.0001, hasData: false) == true, "監視失敗時は通す（フェイルオープン）")
        check(gate.keep(maxRMS: nil, hasData: true) == true, "範囲内に標本なしは通す")
        check(gate.keep(maxRMS: 0.01, hasData: true) == true, "閾値ちょうどは通す")
        let origin = Date()
        let block = TranscriptBlock(id: 2, t0ms: 10000, t1ms: 15000, segments: [])
        var queried: (Date, Date)?
        let kept = gate.keep(block: block, audioStart: origin, levelIn: { start, end in
            queried = (start, end)
            return 0.05
        }, hasData: true)
        check(kept, "ブロック指定でも通す")
        check(queried?.0 == origin.addingTimeInterval(10) && queried?.1 == origin.addingTimeInterval(15),
              "論理時刻→時刻範囲の変換")
        if failures > 0 { exit(1) }
        print("ALL PASS")
    }
}

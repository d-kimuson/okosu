// DuplicateGuard のスタンドアロンテスト。
// 使い方: cp Sources/Okosu/WhisperStreamParser.swift Sources/Okosu/DuplicateGuard.swift /tmp/dtest/ &&
//   cp Tools/dedup-test.swift /tmp/dtest/main.swift && swiftc -o /tmp/dedup-test /tmp/dtest/*.swift && /tmp/dedup-test
import Foundation

var failures = 0
func check(_ cond: Bool, _ label: String) {
    if cond {
        print("ok: \(label)")
    } else {
        failures += 1
        print("NG: \(label)")
    }
}

func block(_ id: Int, _ t0: Int, _ t1: Int, _ text: String) -> TranscriptBlock {
    TranscriptBlock(id: id, t0ms: t0, t1ms: t1, segments: [TranscriptSegment(timestamp: nil, text: text)])
}

// 1. 重なる窓の同一内容は重複
do {
    var guard_ = DuplicateGuard()
    check(!guard_.isDuplicate(block(0, 0, 8000, "こんにちは")), "初出は通す")
    check(guard_.isDuplicate(block(1, 2000, 10000, "こんにちは")), "重なり窓の同文は重複")
    check(guard_.isDuplicate(block(2, 4000, 12000, "こんにちは")), "3連続も重複")
}

// 2. 時刻が重ならない同文は意図的反復として通す
do {
    var guard_ = DuplicateGuard()
    check(!guard_.isDuplicate(block(0, 0, 8000, "はい")), "初出は通す")
    check(!guard_.isDuplicate(block(1, 9000, 17000, "はい")), "非重なり同文は通す")
}

// 3. 異内容は通す（時刻重なりありでも）
do {
    var guard_ = DuplicateGuard()
    check(!guard_.isDuplicate(block(0, 0, 8000, "おはよう")), "初出は通す")
    check(!guard_.isDuplicate(block(1, 2000, 10000, "おはようございます")), "異文は通す")
}

// 4. 空文は捨てる
do {
    var guard_ = DuplicateGuard()
    check(guard_.isDuplicate(block(0, 0, 8000, "  \n ")), "空文は重複扱い（捨てる）")
}

if failures == 0 {
    print("ALL PASS")
} else {
    print("\(failures) FAILURES")
    exit(1)
}

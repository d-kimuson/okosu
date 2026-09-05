// DuplicateGuard v2 のスタンドアロンテスト。
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

// 1. 重なる窓の同一内容は抑止
do {
    var guard_ = DuplicateGuard()
    check(guard_.process(block(0, 0, 8000, "こんにちは")) == "こんにちは", "初出は通す")
    check(guard_.process(block(1, 2000, 10000, "こんにちは")) == nil, "重なり窓の同文は抑止")
    check(guard_.process(block(2, 4000, 12000, "こんにちは")) == nil, "3連続も抑止")
}

// 2. 句点ゆれの近似重複は抑止
do {
    var guard_ = DuplicateGuard()
    check(guard_.process(block(0, 0, 8000, "こんにちは")) == "こんにちは", "初出は通す")
    check(guard_.process(block(1, 2000, 10000, "こんにちは。")) == nil, "句点付き再掲は抑止")
}

// 3. 伸びた窓ずれは差分だけ追記
do {
    var guard_ = DuplicateGuard()
    check(guard_.process(block(0, 0, 8000, "聞こえますか")) == "聞こえますか", "初出は通す")
    let appended = guard_.process(block(1, 2000, 10000, "聞こえますかね?"))
    check(appended == "ね?", "伸び分だけ追記（\(appended ?? "nil")）")
}

// 4. 時刻が重ならない同文は意図的反復として通す
do {
    var guard_ = DuplicateGuard()
    check(guard_.process(block(0, 0, 8000, "はい")) == "はい", "初出は通す")
    check(guard_.process(block(1, 9000, 17000, "はい")) == "はい", "非重なり同文は通す（意図的反復）")
}

// 5. 異内容は通す（時刻重なりありでも）
do {
    var guard_ = DuplicateGuard()
    check(guard_.process(block(0, 0, 8000, "おはよう")) == "おはよう", "初出は通す")
    check(guard_.process(block(1, 2000, 10000, "今日は晴れです")) == "今日は晴れです", "異文は通す")
}

// 6. 空文は捨てる
do {
    var guard_ = DuplicateGuard()
    check(guard_.process(block(0, 0, 8000, "  \n ")) == nil, "空文は捨てる")
}

// 7. 短い偶然一致ではマージしない
do {
    var guard_ = DuplicateGuard()
    check(guard_.process(block(0, 0, 8000, "そうです")) == "そうです", "初出は通す")
    check(guard_.process(block(1, 2000, 10000, "ですよね")) == "ですよね", "短アンカーは通す")
}

if failures == 0 {
    print("ALL PASS")
} else {
    print("\(failures) FAILURES")
    exit(1)
}

// WhisperStreamParser のスタンドアロンテスト。
// 使い方: swiftc -o /tmp/parser-test Sources/Okosu/WhisperStreamParser.swift Tools/parser-test.swift && /tmp/parser-test
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

// 1. 基本ブロック
do {
    let p = WhisperStreamParser()
    var got: [TranscriptBlock] = []
    p.onBlock = { got.append($0) }
    p.feed("[Start speaking]\n\n### Transcription 3 START | t0 = 12000 ms | t1 = 18500 ms\n\n[00:00:12.000 --> 00:00:18.500]  こんにちは\n\n### Transcription 3 END\n")
    check(got.count == 1, "1ブロック確定")
    check(got.first?.id == 3 && got.first?.t0ms == 12000 && got.first?.t1ms == 18500, "START時刻パース")
    check(got.first?.text == "こんにちは", "本文抽出（タイムスタンプ除去）")
}

// 2. チャンク分割（行途中での断片化に耐える）
do {
    let p = WhisperStreamParser()
    var got: [TranscriptBlock] = []
    p.onBlock = { got.append($0) }
    p.feed("### Transcription 1 ST")
    p.feed("ART | t0 = 0 ms | t1 = 2000 ms\n[00:00:00.000 --> 00:00:02.000]  おは")
    p.feed("ようございます\n### Transcription 1 END\n")
    check(got.count == 1 && got.first?.text == "おはようございます", "断片化チャンクでも確定")
}

// 3. 複数セグメント＋SPEAKER_TURN除去
do {
    let p = WhisperStreamParser()
    var got: [TranscriptBlock] = []
    p.onBlock = { got.append($0) }
    p.feed("### Transcription 0 START | t0 = 0 ms | t1 = 5000 ms\n[00:00:00.000 --> 00:00:02.000]  一文目\n[00:00:02.000 --> 00:00:05.000]  二文目 [SPEAKER_TURN]\n### Transcription 0 END\n")
    check(got.first?.text == "一文目\n二文目", "複数セグメント結合＋SPEAKER_TURN除去")
    check(got.first?.segments.count == 2, "セグメント数2")
}

// 4. ブロック外ノイズは無視・ENDなしはflushで破棄
do {
    let p = WhisperStreamParser()
    var got: [TranscriptBlock] = []
    p.onBlock = { got.append($0) }
    p.feed("whisper_init_from_file: loading model...\n[Start speaking]\n")
    p.feed("### Transcription 9 START | t0 = 1 ms | t1 = 2 ms\n[00:00:00.001 --> 00:00:00.002]  未完")
    p.flush()
    check(got.isEmpty, "ENDなしブロックは確定しない")
    p.feed("### Transcription 10 START | t0 = 3 ms | t1 = 4 ms\ntext without timestamp\n### Transcription 10 END\n")
    check(got.count == 1 && got.first?.text == "text without timestamp", "素テキスト行も拾う")
}

// 5. 対応しないEND・空本文セグメント
do {
    let p = WhisperStreamParser()
    var got: [TranscriptBlock] = []
    p.onBlock = { got.append($0) }
    p.feed("### Transcription 5 END\n")
    check(got.isEmpty, "STARTなしENDは無視")
}

if failures == 0 {
    print("ALL PASS")
} else {
    print("\(failures) FAILURES")
    exit(1)
}

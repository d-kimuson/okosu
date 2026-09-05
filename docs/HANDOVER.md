# Okosu 引き継ぎ Doc

最終更新: 2026-09-06 / 作成: 初期スキャフォールド時点

## これは何か

ホットキー（既定 ⌘M）で呼び出す日本語 dictation アプリ。
任意のフォームに自然言語で入力するための個人利用ツール。
PoC は `~/repos/poc-ja-transcribe`（以下 PoC リポジトリ）にあり、本リポジトリは製品化の器。

## PoC で確定したこと（詳細は PoC リポジトリの README）

- モデル: **Kotoba-Whisper v2.0** に固定。拡張性は持たせない方針。
  - faster-whisper: `kotoba-tech/kotoba-whisper-v2.0-faster`
  - GGML: `kotoba-tech/kotoba-whisper-v2.0-ggml`（`ggml-kotoba-whisper-v2.0-q5_0.bin` を使用）
  - Core ML encoder: 自作（`tools/coreml-encoder/` + `models/*-encoder.mlmodelc`）。再現手順あり
- 実測（同一60秒音声・MacBook Pro M3 Pro）:
  - faster-whisper CPU int8: RTF 0.17
  - whisper.cpp Metal: RTF 0.05
  - **whisper.cpp ANE: RTF 0.02（faster-whisper の約7倍）**
- live 方針: **`whisper-stream --step 0`（VAD モード）の標準出力をパース**する。
  発話区切りごとに `### Transcription N START/END` ブロックが出る = 確定単位。
  パースは難しくない。暫定表示の書き換えは whisper-stream 側が面倒を見る
  （毎ステップ窓全体をデコードし直して行上書きする仕組み。PoC で実機確認済み）

## 現状（本リポジトリ）

- `project.yml`（xcodegen）→ `Okosu.xcodeproj` を生成。**xcodeproj 自体はコミットしない**
  （生成物。`xcodegen generate` で作り直す）
- `Sources/Okosu/`: メニューバー常駐（LSUIElement、Dock なし）＋ポップオーバー＋
  ⌘M トグル（`KeyboardShortcuts`）
- **録音・文字起こしは実装済み（2026-09-06）**:
  - `WhisperStreamRunner.swift`: whisper-stream 子プロセス管理（`--step 0 -l ja` の
    VAD モード）。stdout→パーサ、stderr で `Core ML model loaded` 検出（ANE 判定）と
    末尾ログ保持（異常終了時の診断用）。終了猶予 2 秒→kill
  - `WhisperStreamParser.swift`: `### Transcription N START/END` ブロックを確定単位として
    パース（`[t --> t] 本文` のタイムスタンプ除去、`[SPEAKER_TURN]` 除去、チャンク断片化耐性）。
    スタンドアロンテストあり（`Tools/parser-test.swift`、全9件パス）
  - `WhisperBinary.swift`: 実行ファイル解決（同梱 Resources→`OKOSU_WHISPER_STREAM`→
    定番パス→PATH）。**バンドル同梱は未対応**（野良配布時に要検討）
  - `ModelManager.swift`: `~/Library/Application Support/Okosu/` 配置。GGML なければ
    HF から DL（進捗表示あり）。mlmodelc は自動取得しない（単一ファイル DL 不可のため。
    置けば ANE、なければ Metal フォールバック＋ヒント表示）
  - `TranscriptionStore.swift`: 起動時にマイク許可→バイナリ→モデル→起動の順で boot
    （常駐＋掴みっぱなし＝ウォームアップ）。確定ブロック列を真実として保持
  - `ContentView.swift`: 確定行の追記表示（自動スクロール）＋ダブルクリック編集＋
    右クリック削除＋コピー/クリア。準備中は進捗表示、エラー時はメッセージ＋再試行
  - `AppDelegate.swift`: 起動時 `store.start()`、終了時 `stop()`。エンジンエラー時は
    ポップオーバーを自動表示（無言失敗にしない）
  - 開始/停止ボタン（2026-09-06）: フッターの `開始`/`停止` で録音＋文字起こしを切替。
    停止しても確定済みテキストは保持。`stop()` は世代カウンタで取り残し boot を無効化
    するため、起動シーケンス中の停止→再開始も安全。ヘッダのマイクアイコンが状態連動
  - セッションカード方式（2026-09-06）: VAD 発話区切りごとのカードを廃止し、
    1カード＝開始→停止の区間。確定チャンクはカード内に機械的な改行区切りで追記
    （文境界の判定なし）。カード右上に編集（TextEditor＋保存/キャンセル）・コピー
    （コピー済み表示あり）。フッターの `すべてコピー` は全文結合
  - 設定ウィンドウ（2026-09-06）: LSUIElement のため自前 NSWindow 管理。
    ポップオーバーヘッダの歯車→`openSettings` 通知→`AppDelegate.openSettings()`。
    内容: ホットキー変更（`KeyboardShortcuts.Recorder`）、ログイン時起動
    （`SMAppService`）、モデル情報、終了ボタン。
    ※ SwiftUI の `Settings` シーンはメニューバーがないため使えない
- ビルド＆起動確認済み（`BUILD SUCCEEDED`、swiftlint 0 violations、`.app` 常駐確認）

## 開発手順

```bash
cd ~/repos/okosu
direnv allow            # 初回のみ（flake の有効化）
nix develop --command xcodegen generate   # 初回・project.yml 変更時
env -u SDKROOT -u LD DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Okosu -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Okosu-*/Build/Products/Debug/Okosu.app
```

※ direnv が有効なシェルでは flake の shellHook が `SDKROOT`/`LD` を除去するので
`xcodebuild` を直接叩ける。詳細は後述「ハマりどころ」。

## 次の実装ステップ（提案順）

1. ✅ **whisper-stream プロセスの起動・パース**（2026-09-06 実装。上記「現状」参照）
2. ✅ **ウォームアップ**（常駐＋掴みっぱなし方式で実装。無音1秒の空推論は未実施
   → 実機で初回 ANE 準備約30秒が要るか確認すること）
3. ✅ **クリップボードコピー＋編集 UI**（コピー/クリア＋行編集まで実装。
   「終了時自動コピー」は未実装。⌘M はポップオーバー開閉のみ）
4. **手元実機での動作確認（未実施・要マニュアル操作）**:
   a. whisper-stream は flake 管理（`~/repos/okosu#whisper-cpp`→profile。
      `nix profile install ~/repos/okosu#whisper-cpp` 済み。imperative な
      `nixpkgs#` 指定は使わないこと。flake.nix の `packages` 参照）。
      代替: `/opt/homebrew/bin` 配下や `OKOSU_WHISPER_STREAM` でも自動解決する
   b. アプリ起動→マイク許可ダイアログで許可（TCC のため CLI では付与不可）
   c. ポップオーバーが「受付中（ANE）」になること、発話→確定行追記→コピーを確認
   d. 初回 ANE コンパイル時間の実測（HANDOVER 既存値: 約30秒）
   ※ このマシンでは `~/Library/Application Support/Okosu/` に PoC モデルへの
   シンボリックリンク済み（ggml bin＋mlmodelc。再 DL・複製なし）
5. 後回し: バイナリのバンドル同梱、自動ペースト、句読点復元、個人辞書、
   LLM 整形モード、設定画面

## ハマりどころ（実績）

- **xcodegen は新ファイル追加のたびに再生成が必要**: `sources: Sources/Okosu` 指定でも
  生成済み pbxproj はファイル列挙式のため。`nix develop --command xcodegen generate`
- **`URLSession.bytes(from:)` は1バイトずつ列挙**: 0.5GB 級 DL には使えない。
  進捗付き DL は `URLSessionDownloadDelegate` 方式にした（`ModelManager.swift`）
- **`@MainActor` クラスは AppDelegate から直接 `init` できない**
  （Swift 6）。`TranscriptionStore` はメソッド単位 `@MainActor`＋非隔離 init にした
- **`.onChange(of:)` は新2引数形式**（Xcode 26）: `.onChange(of: x) { _, _ in … }`
- **swiftlint default ルールで自作分は 0 violations 維持**: `Vendor/` は対象外
  （`swiftlint lint --strict Sources/Okosu/*.swift` で確認）

## ハマりどころ（旧実績）

- **nix 環境変数が Xcode ビルドを壊す**: pi 実行環境の `SDKROOT`（nix apple-sdk 指し →
  SwiftShims 解決失敗）と `LD=ld`（nix の ld を引く → リンク失敗）。flake の
  shellHook で除去＋ `DEVELOPER_DIR` を system Xcode に固定。Xcode 自体は
  Apple 製なので nix 管理外（方針: nix は xcodegen / swiftlint のみ提供）
- **SPM の KeyboardShortcuts がリンク失敗**: 上記の `LD` 問題が主因だった可能性が高いが、
  切り分け時に `Sources/Okosu/Vendor/` にソース同梱（MIT、LICENSE 同梱済み）に変更。
  `.module` → `.main` の1行修正あり。SPM に戻すことも可能（未検証）
- **xcodegen 2.44.1**: `info:` に `path` 必須（`properties` のみ不可）。
  `INFOPLIST_KEY_*` 設定で代替したので `info:` は使っていない
- **ディスク**: PoC 作業中に CoreML 変換の一時ファイルで逼迫したことがある。
  mlmodelc（1.2GB）＋ggml（0.5GB）は `models/` に置き git 管理外

## 権限メモ（個人利用・野良配布前提）

- マイク: `NSMicrophoneUsageDescription` 設定済み
- グローバルホットキー: Carbon API（同梱 KeyboardShortcuts）でアクセシビリティ不要
- 自動ペーストを付ける場合はアクセシビリティが必要になる。MVP は手動 ⌘V 推奨
- Mac App Store は狙わない（Developer ID＋公証で配布）

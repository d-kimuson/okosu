# Okosu

ホットキー（既定 ⌘M）で呼び出す日本語 dictation アプリ for macOS。
メニューバー常駐で、マイク入力をリアルタイム文字起こしする個人利用ツール。
エンジンは [Kotoba-Whisper v2.0](https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0)（whisper-stream、5秒の非重複窓）。

## 文字起こし方式（開発版）

- 音声を **5秒単位**でまとめて認識・追記する（表示まで最大約5秒＋推論時間）。
- `--step 5000 --length 5000 --keep 0` で前の音声を次の窓に持ち越さない。
  重なる音声の再認識が原因だった二重追記を避け、文字列の重複排除には依存しない。
  意図的に同じ言葉を繰り返した場合はそのまま残す。
- 停止すると「最後の音声を処理中…」になり、5秒未満の末尾も推論してから終了する。
  ホットキー終了のコピーも末尾回収後に行う。処理中は再開始できない。
  ただしエンジンが推論中に停止した場合、推論中に届いた直近の音声が未処理になる可能性がある
  （whisper-stream 自体の終了経路の制限）。
  15秒以内に終了しない場合は強制終了し、確定済みの内容を保持してエラーを表示する。
- トレードオフ：窓境界が単語の途中になることがある。音声 VAD を使わないため、
  無音・雑音からの誤認識も実音声で確認が必要。モデル自体の反復生成までは防がない。
- PoC のローリング窓＋結果安定化とは異なる。そちらは文脈を保ちやすい反面、
  認識の言い換えをまたぐ重複判定が再び必要になるため、まず非重複窓を試す。

## インストール（Release 版）

[Releases](https://github.com/d-kimuson/okosu/releases) から最新の ZIP を取得：

1. ZIP を展開し、`Okosu.app` を `/Applications` に移動
2. 初回のみ Gatekeeper の許可が必要（未署名配布のため）。どちらか一方：
   - `Okosu.app` を右クリック→「開く」
   - または `xattr -d com.apple.quarantine /Applications/Okosu.app`
3. 起動→メニューバーのマイクアイコンから操作（ホットキー既定: ⌘M）
4. 初回起動時に文字起こしモデル（約 0.5GB）を自動ダウンロード

Apple Silicon 専用。詳細は [docs/HANDOVER.md](docs/HANDOVER.md)。

## 開発

```bash
direnv allow            # 初回のみ
nix develop --command xcodegen generate   # 初回・project.yml 変更時
xcodebuild -scheme Okosu -configuration Debug build  # direnv 有効時
bash Tools/test.sh  # パーサ・窓設定・子プロセス停止時の末尾回収（マイク不要）
swiftlint lint --strict Sources/Okosu/*.swift
```

Release 作成は `scripts/release.sh [vX.Y.Z]`（ビルド→whisper-stream 同梱→ZIP→GitHub Release）。

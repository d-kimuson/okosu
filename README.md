# Okosu

ホットキー（既定 ⌘M）で呼び出す日本語 dictation アプリ for macOS。
メニューバー常駐で、マイク入力をリアルタイム文字起こしする個人利用ツール。
エンジンは [Kotoba-Whisper v2.0](https://huggingface.co/kotoba-tech/kotoba-whisper-v2.0)（whisper-stream VAD モード）。

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
```

Release 作成は `scripts/release.sh [vX.Y.Z]`（ビルド→whisper-stream 同梱→ZIP→GitHub Release）。

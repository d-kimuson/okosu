#!/usr/bin/env bash
# Release ビルド→同梱→ZIP→GitHub Release まで一括で行う。
#
# 前提: 未署名配布 (Developer ID なし)。他マシンでは初回のみ Gatekeeper 許可が必要。
#   xattr -d com.apple.quarantine /Applications/Okosu.app
#   (または右クリック→「開く」)
#
# 使い方:
#   scripts/release.sh [vX.Y.Z]
#   既定バージョンは project.yml の MARKETING_VERSION。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-v$(awk '/MARKETING_VERSION/ {gsub(/[";]/, ""); print $3}' project.yml)}"
TAG="$VERSION"
if [[ "$TAG" != v* ]]; then TAG="v$TAG"; fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "[release] 作業ツリーが dirty です。commit してから実行してください。" >&2
  git status --short | head -10
  exit 1
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "[release] $TAG は既存です。中止します。" >&2
  exit 1
fi

DIST="dist"
APP_SRC="$(ls -dt ~/Library/Developer/Xcode/DerivedData/Okosu-*/Build/Products/Release/Okosu.app 2>/dev/null | head -1 || true)"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "[release] $TAG をビルドします (Release)…"
env -u SDKROOT -u LD DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Okosu -configuration Release build

APP_SRC="$(ls -dt ~/Library/Developer/Xcode/DerivedData/Okosu-*/Build/Products/Release/Okosu.app | head -1)"
cp -R "$APP_SRC" "$DIST/Okosu.app"

echo "[release] whisper-stream を同梱します…"
./scripts/bundle-deps.sh "$DIST/Okosu.app"

ZIP="$DIST/Okosu-$TAG-macos-arm64.zip"
echo "[release] ZIP 化します…"
(cd "$DIST" && ditto -c -k --sequesterRsrc --keepParent Okosu.app "$(basename "$ZIP")")

cat > "$DIST/notes-$TAG.md" <<EOF
## インストール

1. ZIP を展開し、\`Okosu.app\` を \`/Applications\` に移動
2. 初回のみ Gatekeeper の許可が必要です。どちらか一方:
   - \`Okosu.app\` を右クリック→「開く」
   - または \`xattr -d com.apple.quarantine /Applications/Okosu.app\`
3. 起動→メニューバーのマイクアイコンから操作 (ホットキー既定: ⌘M)

## 注意

- 未署名配布のため、上記 2 の手順が必要です (Developer ID 取得後に解消予定)。
- 初回起動時に文字起こしモデル (約 0.5GB) を自動ダウンロードします。
- Apple Silicon 専用 (Intel Mac 非対応)。
- Core ML encoder がない環境では Metal 動作になります (十分高速です)。
EOF

echo "[release] GitHub Release を作成します…"
gh release create "$TAG" "$ZIP" --title "Okosu $TAG" --notes-file "$DIST/notes-$TAG.md"

echo "[release] 完了: $TAG"

#!/usr/bin/env bash
# whisper-stream とその dylib closure を .app に同梱する。
#
# 背景: whisper-stream は nix 由来で、依存 dylib を絶対パス (/nix/store/…)
# 参照している。他マシンでは /nix がないため、Frameworks にコピーして
# @executable_path 相対に書き換える。モデル (GGML) は同梱せず初回起動時 DL
# (ModelManager 参照)。mlmodelc も同梱しない (なければ Metal 動作)。
#
# 使い方:
#   scripts/bundle-deps.sh <Okosu.app> [whisper-stream のパス]
#   既定の whisper-stream は ~/.nix-profile/bin/whisper-stream
#   (flake 管理: `nix profile install ~/repos/okosu#whisper-stream`)
#
# 処理後にアドホック再署名する (install_name_tool で署名が壊れるため)。
# 署名が変わるとマイク許可の TCC がリセットされる点に注意 (再許可が必要)。
set -euo pipefail

APP="${1:?usage: bundle-deps.sh <Okosu.app> [whisper-stream]}"
WS_INPUT="${2:-$HOME/.nix-profile/bin/whisper-stream}"

# シンボリックリンクを解決して実体を得る (nix profile は store への symlink)。
# BSD readlink に -f がないためループで辿る。
WS="$WS_INPUT"
while [[ -L "$WS" ]]; do
  link="$(readlink "$WS")"
  [[ "$link" == /* ]] && WS="$link" || WS="$(dirname "$WS")/$link"
done
if [[ ! -x "$WS" ]]; then
  echo "[bundle-deps] 実行可能な whisper-stream がありません: $WS_INPUT" >&2
  exit 1
fi

RES="$APP/Contents/Resources"
FW="$APP/Contents/Frameworks"
mkdir -p "$RES" "$FW"

echo "[bundle-deps] whisper-stream: $WS"

# 1. バイナリを Resources に配置 (WhisperBinary.resolve の第1候補)。
cp -f "$WS" "$RES/whisper-stream"
chmod +x "$RES/whisper-stream"

# 2. dylib closure を Frameworks に収集 (otool -L を幅優先で辿る)。
declare -A SEEN=()
QUEUE=("$RES/whisper-stream")
while ((${#QUEUE[@]} > 0)); do
  BIN="${QUEUE[0]}"
  QUEUE=("${QUEUE[@]:1}")
  while IFS= read -r ref; do
    [[ "$ref" == /nix/store/* ]] || continue
    [[ "$ref" == *.dylib ]] || continue
    if [[ -z "${SEEN[$ref]:-}" ]]; then
      SEEN["$ref"]=1
      QUEUE+=("$ref")
    fi
  done < <(otool -L "$BIN" | awk '{print $1}' | grep '^/')
done

echo "[bundle-deps] dylib closure (${#SEEN[@]}):"
for ref in "${!SEEN[@]}"; do
  base="$(basename "$ref")"
  echo "  $base"
  # 実体をコピー (参照名と同名の実ファイルとして置く。symlink は辿られる)。
  cp -f "$ref" "$FW/$base"
  chmod +w "$FW/$base"
done

# 3. @executable_path 相対に書き換える。
#    プロセスの main executable は Resources/whisper-stream なので、
#    @executable_path/../Frameworks が Frameworks を指す (全参照で統一)。
RPATH_FW='@executable_path/../Frameworks'
change_refs() {
  local target="$1"
  while IFS= read -r ref; do
    [[ "$ref" == /nix/store/* ]] || continue
    [[ "$ref" == *.dylib ]] || continue
    install_name_tool -change "$ref" "$RPATH_FW/$(basename "$ref")" "$target"
  done < <(otool -L "$target" | awk '{print $1}' | grep '^/')
}

change_refs "$RES/whisper-stream"
for lib in "$FW"/*.dylib; do
  install_name_tool -id "$RPATH_FW/$(basename "$lib")" "$lib"
  change_refs "$lib"
done

# 4. アドホック再署名 (奥から順に。app 本体は最後)。
codesign --force --sign - --timestamp=none "$FW"/*.dylib
codesign --force --sign - --timestamp=none "$RES/whisper-stream"
codesign --force --sign - --timestamp=none "$APP"

echo "[bundle-deps] 同梱完了。残参照チェック:"
leftovers="$(otool -L "$RES/whisper-stream" | grep '/nix/store' || true)"
if [[ -n "$leftovers" ]]; then
  echo "$leftovers" >&2
  echo "[bundle-deps] ERROR: /nix/store 参照が残っています" >&2
  exit 1
fi
echo "  /nix/store 参照なし OK"
"$RES/whisper-stream" --help >/dev/null 2>&1 && echo "  同梱バイナリ起動 OK"

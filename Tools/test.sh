#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
unset SDKROOT LD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sources=(Sources/Okosu/WhisperStreamParser.swift Sources/Okosu/WhisperStreamRunner.swift Sources/Okosu/WhisperBinary.swift)
for test in parser dedup; do
  # 既存のトップレベル式テストは main.swift というファイル名でコンパイルする。
  cp "Tools/$test-test.swift" "$work/main.swift"
  swiftc Sources/Okosu/WhisperStreamParser.swift Sources/Okosu/DuplicateGuard.swift "$work/main.swift" -o "$work/$test"
  "$work/$test"
done
for test in window runner; do
  swiftc "${sources[@]}" "Tools/$test-test.swift" -o "$work/$test"
done
"$work/window"
cp Tools/fake-whisper.py "$work/fake-whisper"
chmod +x "$work/fake-whisper"
"$work/runner" "$work/fake-whisper"

#!/bin/bash
# swiftc で RaidenCore（静的ライブラリ）・raiden-eval・Raiden.app を作る。Xcode は不要（Command Line Tools だけ）。
# swift build を使わないのは、この Mac の CLT だと Package.swift のリンクが落ちるため（Knobby と同じ事情）。
# clt-overlay.yaml は CLT に残った古い module.modulemap（SwiftBridging の二重定義）を空に見せる。
#
#   scripts/build.sh            ビルドだけ（build/Raiden.app, build/raiden-eval）
#   scripts/build.sh --install  ~/Applications/Raiden.app に入れて起動し直す
#
# モデル: RAIDEN_MODEL_DIR（既定 /Volumes/SSD/raiden-models）の中から
#   vocab.bin, embed_int8.bin, embed_scale.bin, meta.json, body_${RAIDEN_BODY:-int4}.mlpackage を同梱する。
set -euo pipefail
cd "$(dirname "$0")/.."
MODEL_DIR="${RAIDEN_MODEL_DIR:-/Volumes/SSD/raiden-models}"
BODY="${RAIDEN_BODY:-int4}"
OV="-vfsoverlay scripts/clt-overlay.yaml -Xcc -ivfsoverlay -Xcc scripts/clt-overlay.yaml"
TARGET="-target arm64-apple-macosx15.0"

mkdir -p build/obj
touch build/.metadata_never_index
swiftc -O -swift-version 5 $TARGET $OV -parse-as-library -module-name RaidenCore \
  -emit-library -static -emit-module -emit-module-path build/obj/RaidenCore.swiftmodule \
  -o build/obj/libRaidenCore.a app/Sources/RaidenCore/*.swift
swiftc -O -swift-version 5 $TARGET $OV -I build/obj -L build/obj -lRaidenCore -lsqlite3 \
  app/Sources/raiden-eval/*.swift -o build/raiden-eval
swiftc -O -swift-version 5 $TARGET $OV -I build/obj -L build/obj -lRaidenCore -lsqlite3 \
  app/Sources/Raiden/*.swift -o build/Raiden

APP=build/Raiden.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/model"
cp build/Raiden "$APP/Contents/MacOS/Raiden"
cp app/Resources/Info.plist "$APP/Contents/Info.plist"
for f in vocab.bin embed_int8.bin embed_scale.bin meta.json; do cp "$MODEL_DIR/$f" "$APP/Contents/Resources/model/"; done
# 本体はコンパイル済み（.mlmodelc）で入れる。コンパイルは raiden-eval --compile（MLModel.compileModel）で行う
./build/raiden-eval --compile "$MODEL_DIR/body_$BODY.mlpackage" "$APP/Contents/Resources/model/body.mlmodelc"
codesign --force --deep --sign - --identifier com.kosuke.raiden "$APP"
echo "built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  osascript -e 'quit app id "com.kosuke.raiden"' 2>/dev/null || true
  sleep 1
  mkdir -p ~/Applications
  rm -rf ~/Applications/Raiden.app
  cp -R "$APP" ~/Applications/Raiden.app
  open ~/Applications/Raiden.app
  echo "installed ~/Applications/Raiden.app"
fi

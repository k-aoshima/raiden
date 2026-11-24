#!/bin/bash
# swiftc で RaidenCore（静的ライブラリ）・raiden-eval・Raiden.app を作る。Xcode は不要（Command Line Tools だけ）。
# swift build を使わないのは、この Mac の CLT だと Package.swift のリンクが落ちるため（Knobby と同じ事情）。
# clt-overlay.yaml は CLT に残った古い module.modulemap（SwiftBridging の二重定義）を空に見せる。
#
#   scripts/build.sh            ビルドだけ（build/Raiden.app, build/raiden-eval）
#   scripts/build.sh --install  ~/Applications/Raiden.app に入れて起動し直す
#
# 埋め込みモデルは使わない（同梱しない）。アプリは名前・辞書・記録の文字の一致、ファイルは Spotlight で探す。
set -euo pipefail
cd "$(dirname "$0")/.."
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Raiden "$APP/Contents/MacOS/Raiden"
cp app/Resources/Info.plist "$APP/Contents/Info.plist"
cp app/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R app/Resources/Fonts "$APP/Contents/Resources/Fonts"
# 署名。アドホック（-）だとビルドごとに cdhash が変わり、macOS が別のアプリと見なして、書類・デスクトップ・ダウンロードへの
# アクセス許可を入れ直すたびに聞き直す。キーチェーンの自己署名の証明書（Andon と同じ「Andon Local Signing」）があればそれで署名する
SIGN=$(security find-identity -p codesigning 2>/dev/null | awk -F'"' '/Andon Local Signing/{print $2; exit}')
SIGN=${SIGN:--}
codesign --force --deep --sign "$SIGN" --identifier com.kosuke.raiden "$APP"
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

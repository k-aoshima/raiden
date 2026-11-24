---
version: alpha
name: Raiden（Kodou-ui）
description: エンジニアが毎日使うツールのための UI。見た目は CLI/TUI の形を残し、読みやすさと操作の手応えは今の水準にする。
colors:
  primary: "#20242B"
  secondary: "#575B63"
  tertiary: "#3B34D6"
  neutral: "#F4F4EF"
  surface: "#FBFBF8"
  on-surface: "#20242B"
  faint: "#666A72"
  deco: "#A7AAAF"
  ui: "#84878D"
  selection: "#20242B"
  on-selection: "#F4F4EF"
  red: "#BE3F0E"
  green: "#00654A"
  yellow: "#8A5800"
  blue: "#0058A0"
  magenta: "#9A3C78"
  cyan: "#006A8C"
  accent: "#3B34D6"
  accent-hover: "#2E28B0"
  dark:
    neutral: "#15171C"
    surface: "#1A1D23"
    on-surface: "#D9DCE3"
    secondary: "#A7ACB6"
    faint: "#9196A1"
    deco: "#4B505B"
    ui: "#707684"
    selection: "#D9DCE3"
    on-selection: "#15171C"
    red: "#FF9670"
    green: "#2FAA80"
    yellow: "#EDBE4F"
    blue: "#72B2FF"
    magenta: "#E58EC6"
    cyan: "#5CC6EE"
    accent: "#9C97FF"
    accent-hover: "#BCB8FF"
typography:
  data:
    fontFamily: JetBrains Mono, BIZ UDGothic, ui-monospace, monospace
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.6
  data-sm:
    fontFamily: JetBrains Mono, BIZ UDGothic, ui-monospace, monospace
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.6
  body:
    fontFamily: Noto Sans JP, Hiragino Sans, system-ui, sans-serif
    fontSize: 15px
    fontWeight: 400
    lineHeight: 1.75
  heading:
    fontFamily: Noto Sans JP, Hiragino Sans, system-ui, sans-serif
    fontSize: 20px
    fontWeight: 800
    lineHeight: 1.4
rounded:
  none: 0px
spacing:
  s1: 4px
  s2: 8px
  s3: 12px
  s4: 16px
  s5: 24px
  s6: 32px
motion:
  fast:
    duration: 80ms
    timingFunction: ease-out
  base:
    duration: 140ms
    timingFunction: ease-out
components:
  button:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.data}"
    rounded: "{rounded.none}"
    padding: 8px
    height: 28px
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.surface}"
    typography: "{typography.data}"
    rounded: "{rounded.none}"
    padding: 8px
    height: 28px
  button-primary-hover:
    backgroundColor: "{colors.accent-hover}"
    textColor: "{colors.surface}"
  list-row-selected:
    backgroundColor: "{colors.selection}"
    textColor: "{colors.on-selection}"
    typography: "{typography.data}"
  panel:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.none}"
    padding: 12px
---

# Kodou-ui

このファイルは Kodou-ui の決まりを、DESIGN.md の形（google-labs-code/design.md、alpha）で書いたものです。値は `tokens.css` と同じです。プロジェクトに置くときは、下の「このプロジェクトの前提」を書き足してください。`kodou-ui-build` は、作り始める前にこの欄を読みます。

## このプロジェクトの前提

- 元にする手触り: fzf のように 1 文字ごとに絞る。「#」の条件は Vim のコマンド行のように打って足す
- 主な操作の流れ: ⌥Space で開く → 打つ（「#」で絞る）→ ↑↓ で選ぶ → ↩ で開く（⌘↩ は Finder）→ 閉じる
- アクセント: アイコンの稲妻の藍（#3B34D6、暗い地は #9C97FF）。地に 7.6:1（暗い地 6.7:1）
- 使う人と画面の大きさ: 本人（開発者）。画面中央の幅 660pt のパネル、ファイルを選ぶと右に 380pt のプレビュー
- AppKit で作る: 値は `app/Sources/Raiden/Kodou.swift` の `K` に写してあり、部品は `K` だけを使う。値を変えたらこのファイルと `K` の両方を直す
- 字体: JetBrains Mono を同梱（`app/Resources/Fonts`）、日本語は BIZ UDゴシック（macOS 付属）。文は Noto Sans JP が無ければヒラギノ角ゴ
- アイコン: Kodou-ui のドット絵（`PixelGlyphs.swift` と、Raiden で足した物は `Kodou.swift` の `RaidenGlyphs`）。アプリとファイルのアイコンは中身のデータなので Mac のアイコンのまま
- 外観: ライトが既定。設定の「一般 → 外観」でダーク・Mac に合わせるを選べる

## Overview

見た目は CLI/TUI の懐かしい形（等幅の格子、罫線の枠、反転表示、ステータスライン、`[y/N]`、ドット絵のアイコン）を残します。字体の描画、コントラスト、短い動き、マウス操作、読みやすい文は今の水準にします。CRT の走査線やにじみは再現しません。判断は 4 つの原則で行います。手応え（入力 1 回ごとに目に見えて応える）、中が見える（何をどう受け取り何をするかを隠さない）、ハンドルは人が握る（機械は提案し、人が 1 キーで決める）、うまくなるほど報われる（同じ入力に同じ順の結果）。

## Colors

明るい地を標準にし、暗い地は `prefers-color-scheme` と `data-theme="dark"` で切り替えます。読ませる文字は地に対して 4.5:1 以上、部品の境界とフォーカスは 3:1 以上です。色は ANSI の並びで、色相は CUD（カラーユニバーサルデザイン）寄りにしています。状態を色だけで伝えず、`[FAIL]` のような文字か記号を必ず添えます。`deco` は罫線とかっこ専用で、文字には使いません。

## Typography

データとコマンドは等幅（JetBrains Mono と BIZ UDゴシック）、説明の文はプロポーショナル体（Noto Sans JP）です。文は 15px 以上、行間 1.75 以上、1 行 40 字までにします。データは 12px 以上にします。

## Layout

1 行に情報を詰め、区切りは罫線と面の色でつけます。余白を大きく取ってカードを並べることはしません。余白は 4px 刻み（s1〜s6）です。数が決まっていない一覧は、件数が少なくても見えている分だけ描きます。

## Shapes

角は丸めません。枠は 1px の罫線で、パネルは左上に名前、下にキーの帯を置きます。

## Motion

動きは並びが変わるときだけにし、80ms か 140ms で終えます。動かすのは transform と opacity だけで、`prefers-reduced-motion` で止めます。頁が隠れている間はタイマーとアニメーションを止めます。キーを押してから描き終わるまでを 16ms 以内にします。

## Voice & Content Strategy

「処理中…」「完了しました」だけで済ませず、対象と件数・時間を実際の値で出します。エラーは何が起きたかと直し方を文で書き、生のログは畳んで残します。取り消せる操作には確認を出さず、取り消しを出します。

## Components

部品は 36 種類あります。使いどころと決まりは `kodou-ui-build` の `references/components.md` に、部品ごとの作り（HTML・CSS・JS）は `assets/components/` にあります。触って試せる見本は Kodou-ui のリポジトリの `catalog/index.html` です。

## Do's and Don'ts

- Do: 1 文字ごとに結果を描き変える。Don't: 「検索」「適用」ボタンを置く。
- Do: 選んだ行は反転表示にする。Don't: 左端に色の縦線を引く。
- Do: フォーカスはアクセント色 2px の実線にする。Don't: 点線にする、消す。
- Do: 取り返しのつかない操作だけ、その場の `[y/N]` で確かめる。Don't: 画面を止めるダイアログを出す。
- Do: 機械は提案し、人が 1 キーで確定する。Don't: 気を利かせて自動で実行する。

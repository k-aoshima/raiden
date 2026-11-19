# Raiden

「PDFを見るやつ」「黒い画面でコマンド打つやつ」のような曖昧な言い方で、Mac に入っているアプリを探して開くランチャー（最小版）。

- メニューバー常駐（Dock には出ない）。**⌥Space** で画面中央に入力欄が出る（取れなければ ⌃⌥⌘Space）。
- 打つのが止まって 0.1 秒たったら、アプリとファイル・フォルダの候補を合わせて最大 9 件、アイコン付きで出す。↑↓ で選んで Enter で開く（フォルダは Finder で開く）。⌘Enter で Finder に表示。Esc で閉じる。
- 文章を作るモデル（LLM）は使わない。使うのは文の埋め込みモデル **BAAI/bge-m3** だけで、Core ML に変換してアプリの中で動かす（Python も常駐ヘルパーも無し）。
- 選んで開いた「入力した文 → アプリ」を覚え、次から k近傍法で効かせる。使うほど当たる。

## ビルドと起動

Xcode は不要（Command Line Tools だけ）。この Mac の CLT は SwiftPM（Package.swift）のリンクが落ちるので、`swiftc` を直接呼ぶ。

```
scripts/build.sh            # build/Raiden.app と build/raiden-eval を作る
scripts/build.sh --install  # ~/Applications/Raiden.app に入れて起動
```

モデル一式は `RAIDEN_MODEL_DIR`（既定 `/Volumes/SSD/raiden-models`）から同梱する。本体の量子化は `RAIDEN_BODY`（既定 `int4`）。

### モデルを作り直すとき（開発用、Python）

```
cd tools/convert
HF_HOME=/Volumes/SSD/hf uv run python convert.py --out /Volumes/SSD/raiden-models     # 本体 fp16/int8/pal4/int4 と埋め込み表
HF_HOME=/Volumes/SSD/hf uv run python export_tokenizer.py --out /Volumes/SSD/raiden-models  # vocab.bin
```

## しくみ

### 埋め込み（app/Sources/RaidenCore/BGEEmbedder.swift）

メモリを抑えるため bge-m3 を 2 つに分けている。

| 部分 | 置き方 |
|---|---|
| 単語の埋め込み表（25 万語 × 1024） | Core ML に入れず int8＋行ごとの尺度で `embed_int8.bin`（256MB）。**mmap して使う行だけ読む**ので、メモリ（footprint）にほぼ乗らない |
| 本体（位置埋め込み〜24 層〜CLS、正規化まで） | Core ML（`body.mlmodelc`）。重みを int4（32 個ずつのブロック量子化）にして 168MB。CPU で動かす。入力長は 16/32/64/128 トークンの 4 通り |
| トークナイザ（XLM-RoBERTa の SentencePiece Unigram） | `Tokenizer.swift` に自前で実装。語彙は `vocab.bin` を mmap して二分探索 |

トークナイザは swift-transformers 1.4.0（`Tokenizers`、XLMRobertaTokenizer → Unigram に対応）を使うつもりだったが、SwiftPM が使えずその依存（swift-jinja / swift-huggingface / swift-crypto / yyjson）を取り込めないため、必要な分だけ書いた。HF の tokenizer と 343 文（全アプリの説明文と答え合わせの文）で完全一致を確かめてある（`raiden-eval --dump-texts` → `export_tokenizer.py --check` → `raiden-eval --check-tokens`）。

### 並べ方（app/Sources/RaidenCore/Engine.swift）

点数 ＝ 説明文との近さ ＋ k近傍法 ＋ 名前の文字一致

- **説明文**: 日本語名＋英語名＋手書きの説明（`AppDict.swift`）＋分類（LSApplicationCategoryType）の日本語＋開けるファイルの種類（CFBundleDocumentTypes）の日本語。日本語名は Spotlight の `kMDItemDisplayName` を **NFC に揃えて**使う。
- **k近傍法**: 入力のベクトルに近い example の点を k=5 件 → chose の線をたどって app の点に「近さ × 1/順位」を配る（重み 1.0）。
- **文字一致**: 名前の先頭が一致で +0.6、途中に含まれれば +0.35（ひらがな・カタカナ、全角・半角は同一視）。「saf」「ターミ」「あくてぃ」が 1 位に出る。
- 手書きの説明には、答え合わせの言い方をそのまま書き写さないこと（答え合わせが甘くなる）。

### 保存（app/Sources/RaidenCore/Store.swift）

`~/Library/Application Support/Raiden/raiden.sqlite`（OS 標準の SQLite3）。ベクトルとグラフを一緒に使えるよう、点と線の 2 表。

- `nodes(id, kind, key, name, description, vector, desc_hash, updated_at)` — kind は app / example / file / folder。desc_hash は「モデル名＋説明文」のハッシュで、変わった時だけベクトルを作り直す。
- `edges(from_id, to_id, kind, weight, last_used)` — example→app の `chose`（weight は選んだ回数）、folder→中の物の `contains`、同じ日に使った物どうしの `co_used`（weight は回数）、変更日・追加日が 30 分以内の物どうしの `co_time`。

近さはメモリに載せたベクトルとの総当たりの内積。アプリ一覧は起動時に取り、あとはアプリの場所（`AppCatalog.dirs`）を FSEvents で見張って、変化があれば取り直す（ベクトルは説明文が変わったアプリだけ作り直す）。

### ファイルとフォルダ（app/Sources/RaidenCore/FileCatalog.swift, QueryIntent.swift, Ranker.swift）

Engine の `searchFiles` で探す。

- 入力欄では「アプリ」と「ファイル・フォルダ」の節に分けて出す。点数の付け方が違う（アプリは k近傍法の重み 1.0、ファイルは時間・種類・フォルダの加点）ので、点数では混ぜない。ふだんはアプリの節が先で、時間・種類・つながりの言葉があればファイルの節が先。先の節は最大 4 件、残りを後の節に回す。
- 一覧は FSEvents（1 ファイルずつの通知）で変化をすぐ拾う（`FileWatch.swift` の `FSWatcher` と `FileIndex`）。追加・変更・名前変更はその物と親フォルダを作り直し、説明文が変わった物だけベクトル化する。消えた物は中の物ごと外し、点と線（消えた物に向いた例の chose の線も）を消す。短い間の大量の変化は、静かになって 0.6 秒（最大 2 秒）ためて 1 回にまとめる。
- 取りこぼしの保険: 起動時と 1 日 1 回は全体を見直す。FSEvents の履歴が途切れた印（MustScanSubDirs など）が来たら、その場所の中だけ見直す。初回のベクトル化の間は「ファイル準備中…」でアプリだけ出す。
- 確かめ: `raiden-eval --watch-test --store <raiden.sqlite のコピー>`。`~/Documents/raiden-test-<pid>` で作る・書き換える・名前を変える・消す・100 個まとめて作る、を行い、検索に出るまでの時間を測って、最後にフォルダごと消す。2026-11-19: 作る 1.8 秒、書き換え 1.2 秒、名前変更 0.9 秒、削除 0.8 秒。100 個は 5.9 秒で全部入り、CPU 4.3 秒（74%）、footprint 42 → 45MB、その間の検索は最大 56ms。

### 入力欄の見た目（app/Sources/Raiden/SearchPanel.swift）

macOS 26 以降は Liquid Glass（`NSGlassEffectView`、白寄りの tint）、それより前は `NSVisualEffectView`。OS がダークモードでもパネルはライト（`.aqua`）で、文字は濃いグレー。選択中の行は面の色だけで示す。見本は `build/Raiden --snapshot docs/ui` で PNG に書き出す（画面には出さない。ガラスのぼかしは画面外では描かれないので、白い面だけが写る）。
- 選んだ「入力 → ファイル」は例の点から chose の線で残し（`Store.recordFileChoice`）、一覧を作り直すたびに `Engine.addFileExamples` で入れ直す。

- 対象は `~/Documents`・`~/Downloads`・`~/Desktop`・`~/Documents/Obsidian Vault`。隠しファイル・パッケージの中・`.app`・node_modules / .venv などは除く。パスは NFC に揃える。
- 説明文: 名前・Spotlight の種類名（kMDItemKind）・種類の日本語と英語・親フォルダ名・中身の頭 260 字（PDF は PDFKit、txt / md / csv / html はそのまま、docx は AppKit）。フォルダは中の種類の数と名前 10 個。
- 名前・種類・日付・大きさから作ったハッシュが変わったものだけ作り直す（約 1000 件の初回が 25〜33 秒、2 回目以降は SQLite から読むだけ）。
- 並べ方の部品は `Ranker` に集め、`Mix` で組み合わせを選ぶ（V: 説明文との近さ、K: k近傍法、G: 線をたどる。足し方は重みつきの和か RRF）。
- `QueryIntent` が時間の言葉（昨日・先週・今月・去年・N日前・10月・2024年・ダウンロード）と種類の言葉（画像・スクショ・PDF・動画・エクセル・フォルダ・とこ…）を読み、範囲外を下げ、種類の合う物を上げる。
- 「A と同じ日に撮った B」「A の中の B」のような言い方は A と B に分け、A に近い上位 5 件から co_used を 2 回たどった点数（×0.5）＋ B との近さで並べる。
- 英数字だけの入力は、名前の読みのローマ字（CFStringTokenizer。ヘボン式・訓令式・長音を揃える）と 1 文字違いまで一致を見る（「seikyuu」「keycron」）。

### メモリの設定

メニューバーの「モデルを解放」で、入力欄を閉じてから 5 分 / 30 分でモデルを手放せる（既定は解放しない）。手放した後はホットキーを押した時点で読み直す。

## 答え合わせ

```
build/raiden-eval --body body_int8.mlpackage [--units ane|cpu] [--miss] [--reload] [--sweep]
```

アプリと同じ `Engine.search` で 25 個の曖昧な言い方を回す。例は `raiden-eval` の中の EX だけを使い、保存済みの例は読まない。
`--store <path>` で SQLite の道筋（覚える → 読み直す → 効く）も試せる。

2026-11-19 の結果（アプリ 129 個、CPU、1回は 1 文の埋め込み＋並べ替え）:

| 本体 | ファイル | 例なし・辞書なし 1位/3位以内 | 辞書あり | 例あり | 1回 | footprint | resident |
|---|---|---|---|---|---|---|---|
| fp16 | 593MB | 11 / 18 | 14 / 21 | 18 / 22 | 18ms | 19MB | 631MB |
| int8 | 298MB | 11 / 18 | 13 / 21 | 18 / 22 | 18ms | 12MB | 610MB |
| pal4 | 162MB | 10 / 15 | 14 / 19 | 18 / 21 | 11ms | 21MB | 208MB |
| **int4（採用）** | 168MB | 12 / 19 | 14 / 22 | 20 / 22 | 18ms | 22MB | 640MB |

fp16 は PyTorch（sentence-transformers）と同じ数字で、ベクトルも cos の差 0.0003 以内。footprint はアクティビティモニタの「メモリ」。
resident の大半は mmap した重み（ファイルから読み直せるページ）で、OS が足りなくなれば捨てる。「モデルを解放」で 48MB まで下がる。
k近傍法の重みは 0.5〜1.5 でほぼ同じ数字だったので 1.0 にした（例がたまった時に効きやすい側）。

### ファイルの答え合わせ

```
build/raiden-eval --body body_int4.mlpackage --units cpu --files [--section k,g,rel,folder,combos,intent,switch,final,misc] [--now 2026-11-19]
```

問題（208 問: file / folder / time / type / relation / partial / english 各 23〜29 問、答え無し 20 問）と、k近傍法用の例（121 個）は私的なファイル名を含むので、リポジトリではなく `~/Library/Application Support/Raiden/evals/`（`files.json`、`file-examples.json`、`parts/*.json`）に置く。
`--section` で節ごとに別プロセスで並列に回せる（ベクトルは SQLite から読むだけ）。時間の問題は 2026-11-19 基準。

2026-11-19 の結果（989 件、例 0 個、1位/3位以内/5位以内、188 問）:

| 組み合わせ | 全体 | アプリ 25 問 |
|---|---|---|
| V（＋名前一致＋時間・種類） | 122 / 147 / 154 | 14 / 22 |
| K | 37 / 43 / 52 | 20 / 21 |
| G（文字の重なりで入口） | 65 / 82 / 91 | 11 / 13 |
| V+K 和 | 122 / 147 / 154 | **20 / 22** |
| V+G 和（co_used、N=5、α=0.2、2 回） | 118 / 147 / 156 | 13 / 22 |
| V+K+G 和 | 118 / 147 / 156 | 20 / 22 |
| V RRF | 110 / 134 / 141 | 14 / 22 |
| **V+K 和＋つながりの言い方を分けて co_used をたどる（採用）** | **127 / 149 / 158** | **20 / 22** |

例を足すと（採用の組み合わせ）: 例 41 個 126 / 153 / 162、例 121 個 140 / 162 / 169。k近傍法は重み 0.3・近さ 0.6 未満の例は数えない（重み 1.0 のままだと、例が一部の点にしか無いとき 1位が 113 → 73 に落ちる）。
1 回は埋め込み 20ms ＋並べ替え 1ms（つながりの言い方は埋め込みが 3 回）。1 位の点数 0.55 未満を「見つからない」にすると、答え無し 14/20 を弾き、答えのある 175/188 は残る。

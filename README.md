# Raiden

「PDFを見るやつ」「黒い画面でコマンド打つやつ」のような曖昧な言い方で、Mac に入っているアプリを探して開くランチャー（最小版）。

- メニューバー常駐（Dock には出ない）。**⌥Space** で画面中央に入力欄が出る（取れなければ ⌃⌥⌘Space）。
- 打つたびに候補を最大 8 件、アイコン付きで出す。↑↓ で選んで Enter で開く。Esc で閉じる。
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

- `nodes(id, kind, key, name, description, vector, desc_hash, updated_at)` — kind は app / example（後で file / folder）。desc_hash は「モデル名＋説明文」のハッシュで、変わった時だけベクトルを作り直す。
- `edges(from_id, to_id, kind, weight, last_used)` — example→app の `chose`（weight は選んだ回数）。後で contains / opened_with / co_opened などを足す。

近さはメモリに載せたベクトルとの総当たりの内積。アプリ一覧は起動時と 10 分おき（と入力欄を開いた時に 10 分以上たっていれば）に取り直す。

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

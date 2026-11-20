# Raiden

「PDFを見るやつ」「黒い画面でコマンド打つやつ」のような言い方で、Mac に入っているアプリと、Mac 全体のファイル・フォルダを探して開くランチャー（最小版）。

- メニューバー常駐（Dock には出ない）。**⌥Space** で画面中央に入力欄が出る（取れなければ ⌃⌥⌘Space）。
- 打つのが止まって 0.1 秒たったら、アプリとファイル・フォルダの候補を合わせて最大 9 件、アイコン付きで出す。↑↓ で選んで Enter で開く（フォルダは Finder で開く）。⌘Enter で Finder に表示。Esc で閉じる。
- モデル（LLM・埋め込み）は使わない。アプリは名前・辞書・選んだ記録の文字の一致で、ファイル・フォルダは Spotlight（MDQuery）に問い合わせて探す。自前のファイルの一覧も持たない（2026-11-20 から。下の「埋め込みと自前の一覧をやめた」）。
- 選んで開いた「入力した文 → アプリ / ファイル」を覚え、次から入力の文字が近ければ上に出す。

## ビルドと起動

Xcode は不要（Command Line Tools だけ）。この Mac の CLT は SwiftPM（Package.swift）のリンクが落ちるので、`swiftc` を直接呼ぶ。

```
scripts/build.sh            # build/Raiden.app と build/raiden-eval を作る
scripts/build.sh --install  # ~/Applications/Raiden.app に入れて起動
```

モデルは同梱しない（アプリは 1.8MB。前はモデル込みで 476MB）。

## しくみ

### アプリの並べ方（app/Sources/RaidenCore/Engine.swift, Ranker.swift）

点数 ＝ 名前 ＋ 辞書 ＋ 選んだ記録 ＋ いつも開く・最近使った（どれも文字の一致。`Mix` に重み）

- **名前**: 日本語名・英語名・.app の名前の先頭か単語の先頭 +0.6、途中 +0.35、英数字の入力は読みのローマ字に 1 文字違いまで +0.3（ひらがな・カタカナ、全角・半角は同一視）。アプリは 133 個ほどなので全部を見る（索引は使わない）。
- **辞書**: 手書きの説明（`AppDict.swift`。標準アプリと他社アプリ）＋分類の日本語＋開けるファイルの種類＋自作アプリの材料（`AppExtra`。app-notes.json・README など）を「辞書の言葉」にし、入力の 2 文字の組（ひらがなだけの組は捨てる）がそこに入っている割合 × 0.5（`Describe.dictText`、`Lexical.grams`）。
- **選んだ記録**: 選んで開いた「入力 → アプリ」の入力と、今の入力の 2 文字の組の重なり（Dice）が 0.5 以上なら × 0.5（回数で割り振る）。
- **いつも開く**: 入力に種類の言葉（PDF・ワード・画像…）があれば、手元のその種類をいちばん多く開くアプリに +0.15（`OpenWith.swift`。~/Documents・Downloads・Desktop のファイルを Spotlight で並べ、`NSWorkspace.urlForApplication(toOpen:)` に聞く）。**最近使った**: kMDItemLastUsedDate が新しいほど最大 +0.05（30 日で 1/e）。
- 「見つからない」: 1 位が名前・辞書・記録のどれにも当たっていないとき（`Ranker.Parts.hit`）。
- 利用者の辞書（言い方 → アプリ / ファイル / 「#」の条件）は settings.json の `dictionary`（`PhraseDictionary`。下の「絞り込みのコマンド」）。入力欄の「辞書」の節に出る。

### 自作アプリの説明文（app/Sources/RaidenCore/AppExtra.swift）

標準アプリは手書きの辞書（`AppDict.swift`）があるが、自作アプリは名前と分類くらいしか手がかりが無い。そこで次の材料から短い文を集めて辞書の言葉に足す（合計 360 字まで、前の材料ほど優先）。

1. `~/Library/Application Support/Raiden/app-notes.json`（`{"bundle id か名前": "説明"}`）。自分で書く説明。標準アプリにも効く。リポジトリには入れない。
2. Info.plist の `NSHumanReadableCopyright` / `CFBundleGetInfoString`（普通の著作権表示・版番号・名前そのものは除く）
3. `~/Project/<アプリ名 か bundle id の末尾>` の README.md → CLAUDE.md → .claude/CLAUDE.md → docs/SPEC.md のうち最初に見つかった 1 つの、最初の見出しと最初の段落
4. `NS*UsageDescription`（決まり文句は除く）

`raiden-eval --show-desc` で、アプリごとの辞書の言葉を並べられる。

### ファイルとフォルダ（app/Sources/RaidenCore/SpotlightSearch.swift）

Mac 全体を Spotlight（MDQuery、同期で問い合わせて別の列で待つ）に聞く。自前の一覧・ベクトル・FSEvents の見張りは持たない（この Mac は約 323 万ファイルあり、1 件約 8KB の自前の一覧では持てない）。

- 範囲: ホームの中の各フォルダ（隠しと除外を除く。~/Library は既定で除外）、/Users/Shared、外付けのボリューム。ホーム直下のファイルは範囲にできないので、検索のたびに 1 段だけ見て足す。
- 結果は除外（設定の「除外」のフォルダと名前）、隠しフォルダ・パッケージ（.app・.photoslibrary など）の中を Raiden の側でもう一度ふるう。
- 1 回に受け取るのは 3,000 件まで（`fetchLimit`）。属性は問い合わせの sortingAttrs で一緒に受け取る（1 件ずつ MDItemCopyAttributes すると 2,000 件で 0.45 秒）。
- 打つたびに前の問い合わせを止める（`Engine.cancelFiles` → `MDQueryStop`。10ms 後に止めて 1ms 以内に戻る）。

「#」と言い方 → Spotlight の条件（`SpotlightSearch.request` / `queryString`）:

| 入力 | 条件 |
|---|---|
| 名前の言葉 | `kMDItemDisplayName` / `kMDItemFSName` の部分一致（`"*言葉*"cd`）。空白・ひらがなの所・英数字との境目で区切り（「大阪で泊まった宿の領収書」→ 大阪・領収書）、言葉どうしは「または」で引いて当たった割合で並べる |
| `#name` | 同じ部分一致。値どうしは「または」 |
| `#kind` | `kMDItemContentTypeTree`（pdf → com.adobe.pdf、image → public.image など）か `kMDItemFSName` の末尾（拡張子）。スクショは画像で名前に「スクリーンショット」「screenshot」 |
| `#ext` | `kMDItemFSName == "*.pdf"c` |
| `#type` | `kMDItemContentType == "public.folder"` か、その否定 |
| `#date` | `kMDItemLastUsedDate`・`kMDItemContentModificationDate`・`kMDItemDateAdded`・`kMDItemContentCreationDate` のどれかが範囲に入る。`#modified` は変更日、`#created` は作成日だけ |
| `#path` | `~/` `/` で始まればそこを範囲（searchScopes）に。名前なら、名前にそれを含むフォルダを Spotlight で引いて範囲にする |
| `#with X` | X の `kMDItemLastUsedDate` の前後 30 分（`withWindow`）に使った物。Raiden から開いた記録の co_used の線（30 分以内に続けて開いた物どうし、重みは回数。`Store.recordOpenedTogether`）の重みで +0.3 まで加点し、線の先は Spotlight の結果に無くても入れる。X 自身は外す |
| `#near X` | X から親をさかのぼり、.git・package.json・Package.swift・*.xcodeproj・*.xcworkspace・Cargo.toml・pyproject.toml・Unity の Assets と ProjectSettings の両方、のどれかがある最初のフォルダ（`projectRoot`）を範囲にする。見つからなければ X の親。~ か / で止まる |
| 「#」の無い言い方 | `QueryIntent` の時間・種類の言葉を `#date`・`#kind` と同じ条件に、「〜フォルダ」は `#type d`、「ダウンロードした」は `kMDItemWhereFroms`、「A と同じ日の B」は `#with A`、「A の中の B」は `#path A` |

X は `~/` `/` で始まればそのパス、そうでなければ名前が一致する物（同じ名前 → 名前に含む物、その中は使った日の新しい順）。違うコマンドどうしは「かつ」（`#near X #ext swift` など）。

並べ方: 名前の一致の強さ（先頭・単語の先頭 0.6、途中 0.35、言葉ごとの平均）＋使った日・変えた日の新しさ（最大 0.2、30 日で 1/e）＋「選んだ」記録（入力 → ファイル。入力の 2 文字の組の重なりが 0.5 以上なら 0.5 × 重なり、0.35 以上なら Spotlight の結果に無くても入れる）。「見つからない」は結果が 0 件のとき。

「#」の担当向けの口:

- `SpotlightSearch.recent(limit:)` 最近使ったファイル・フォルダ（kMDItemLastUsedDate の新しい順。7 日 → 30 日 → 1 年と広げる）。20 件で 12ms。
- `SpotlightSearch.count(_ filters:)` 条件に合う物の数（Spotlight の数のまま。除外のふるい直しはしない目安）。
- `SpotlightFilterSource`（`FilterSource` の実装。AppDelegate が `FilterInput.context` に渡す）: 値の候補の件数は、覚えていなければ nil（件数なし）を返して裏で数え（4 本並べて）、届いたら `FilterInput.sourceDidUpdate()` で出し直す。覚えた件数は 60 秒。#with・#near が付いているときは数えない。`recentFiles` / `recentFolders` は入力欄を開いたときに取り直す最近使った物（40 件）。#kind の値 8 つを #date 7d の中で数えて 2.0 秒、2 回目からは覚えた件数。検索とは別の SpotlightSearch で数える（打つたびの取り消しに巻き込まれない）。
- `SpotlightSearch.projectRoot(of:)`、`SpotlightSearch.entry(path:)`（1 件の属性）、`resolve(_:)`（#with / #near の X をパスに）。

### 保存（app/Sources/RaidenCore/Store.swift）

`~/Library/Application Support/Raiden/raiden.sqlite`（OS 標準の SQLite3）。点と線の 2 表。

- `nodes(id, kind, key, name, description, vector, desc_hash, updated_at)` — kind は app / example / file / folder。file / folder は「選んだ」「開いた」記録の相手としてだけ置く。vector・desc_hash は前の版の名残で、今は空。
- `edges(from_id, to_id, kind, weight, last_used)` — example → app / file の `chose`（weight は選んだ回数）、file → app の `opened_with`、Raiden から 30 分以内に続けて開いた物どうしの `co_used`（両向き、weight は回数）、開いた時刻の `opened`（自分への線）。
- 前の版の DB は、起動時に一度だけ片付ける（`Store.dropFileIndex`、meta の `files = spotlight1`）: 記録の相手でないファイル・フォルダの点と contains / co_used / co_time / opens の線を消し、どの点もベクトルを空にし、一覧の保存の印（file_scope・fs_event_id・fs_uuid）を消して VACUUM。本物のコピー（29.2MB）は 0.1MB、~/Project 16.8 万件を入れた DB（60.4MB）は 0.04MB になった。

### 埋め込みと自前の一覧をやめた（2026-11-20）

消した物: bge-m3（BGEEmbedder・Embedder・NLEmbedder・CachedEmbedder・Tokenizer・ANE の読み込みと `compiled/` のキャッシュ）、アプリと例のベクトルと k近傍法、ファイルのベクトル（2 値・中心・並べ直し）、自前のファイルの一覧（FileIndex・FileCatalog の一覧づくり・一覧の保存と起動時の読み込み・ファイルの FSEvents・名前の索引 NameIndex）、contains / co_used（使った日）/ co_time の線、設定の「検索範囲」（探すフォルダと件数・広すぎる場所の目安）と「モデルを解放」、tools/convert（変換の Python）、raiden-eval のベクトル用の計測（--bench-embed・--plan・--bench-binary・fitbin・--nl・--scope-run・--startup-bench・--offline-test・--bench-apply・--bench-rank・--watch-test）。

| | 前（bge-m3・自前の一覧） | 後 |
|---|---|---|
| アプリの大きさ | 476MB | 1.8MB |
| 起動から検索できるまで | モデル 2.4〜2.7 秒（ANE の初回は数分）＋一覧 5.3 秒（~/Project 16.8 万件、保存した一覧から） | 0.21 秒（DB 6ms・いつも開く 68ms・アプリ一覧 120ms） |
| メモリ（footprint） | モデルとアプリだけで 67MB、~/Project 16.8 万件で 1,311MB | 12MB（アプリの答え合わせの後 11MB、Spotlight を 40 回引いた後 26MB） |
| ファイルの検索 1 回 | 22〜32ms（~/Project 16.8 万件、手元の一覧） | Mac 全域で中央 190ms（148〜292ms。Spotlight の同期の問い合わせが 1 回 150〜170ms かかる。範囲が狭い `#near` は 3ms） |
| アプリの検索 1 回 | 2ms | 0.3ms |

### 入力欄の見た目（app/Sources/Raiden/SearchPanel.swift）

macOS 26 以降は Liquid Glass（`NSGlassEffectView`、白寄りの tint）、それより前は `NSVisualEffectView`。透け具合は設定の「一般 → 透明度」（0〜90%、既定 60%）で、ガラスの tint の不透明度 0.65×（1−透明度）、上に重ねる白い面 0.75×（1−透明度）（既定で 0.26 と 0.30。前は 0.55 と 0.62 で固定）。75% 以上はガラスを `.clear`、古い OS は 50% 以上で `.underWindowBackground`（未満は `.popover`）。OS がダークモードでもパネルはライト（`.aqua`）で、文字は濃いグレー。選択中の行は面の色だけで示す。見本は `build/Raiden --snapshot docs/ui` で PNG に書き出す（画面には出さない。ガラスのぼかしは画面外では描かれないので、白い面だけが写る）。

**ファイルのプレビュー**（app/Sources/Raiden/FilePreview.swift）: 候補にファイル・フォルダの行があるときだけ、パネルを中央のまま右に広げ（一覧 660px ＋ プレビュー 380px、0.18 秒）、選んだ行（矢印・マウスを乗せる）の中身を出す。中身は Quick Look のサムネイル（`QLThumbnailGenerator`、PDF・画像・テキスト・コード・動画など）と、名前・種類・大きさ・変更日・場所。フォルダは中身の先頭いくつかと件数、アプリの行はアイコンと名前だけ。行を動かしてから 0.12 秒待って読み、その間に動いたら前の読み込みは取り消す。属性とフォルダの中身は裏のキューで読むので、入力や矢印は待たせない。打っている途中でファイルの行が消えたときは 0.25 秒待ってから狭める。画面の幅が 1120px 未満のときと、設定の「一般 → ファイルのプレビューを出す」（初期値オン）を切ったときは出さない。見本は `docs/ui/panel-preview.png`（`/tmp/raiden-preview-sample` にその場で作った見本のファイルを写す）。
- 選んだ「入力 → ファイル」は例の点から chose の線で残し（`Store.recordFileChoice`）、一覧を作り直すたびに `Engine.addFileExamples` で入れ直す。

- 対象は設定の「検索範囲」（初期値は `~/Documents`・`~/Downloads`・`~/Desktop`・`~/Documents/Obsidian Vault`、除外は node_modules / .venv / venv / __pycache__ / .git / DerivedData / Pods / build / .build / dist / target / .next / .cache / *.log。. で始まる名前はもともと隠しファイルとして除く）。隠しファイル・パッケージの中・`.app` はいつも除く。パスは NFC に揃え、シンボリックリンクはたどった実際のパスにする。
- 説明文: 名前・Spotlight の種類名（kMDItemKind）・種類の日本語と英語・親フォルダ名・中身の頭 260 字（PDF は PDFKit、txt / md / csv / html はそのまま、docx は AppKit）。フォルダは中の種類の数と名前 10 個。
- 名前・種類・日付・大きさから作ったハッシュが変わったものだけ作り直す（989 件の初回が 17.6 秒（前は 29.5 秒）、2 回目以降は SQLite から読むだけ）。
- 並べ方の部品は `Ranker` に集め、`Mix` で組み合わせを選ぶ（V: 説明文との近さ、K: k近傍法、G: 線をたどる。足し方は重みつきの和か RRF）。
- `QueryIntent` が時間の言葉（昨日・先週・今月・去年・N日前・10月・2024年・ダウンロード）と種類の言葉（画像・スクショ・PDF・動画・エクセル・フォルダ・とこ…）を読み、範囲外を下げ、種類の合う物を上げる。
- フォルダを探す言い方（入力の一番後ろの種類の言葉が「フォルダ」「とこ」「置き場」など）のときだけ、フォルダを次のように上げる。「〜フォルダの画像」のように後ろが別の種類なら上げない。
  - 下（何段でも）にファイルが 1 個も無いフォルダには加点しない（説明文が短い空のフォルダが「フォルダ」の言葉だけで上に来ていた）。
  - 「PDFが入ってるとこ」「スクショを分けてるフォルダ」は、下のファイルのうち種類が合う割合 × 0.2 を足す（スクショは画像でも当たり）。
  - 中の物が近さの上位 20 件に 2 件以上いれば、1 件ごとに 0.01 を足す。
  - 時間の言葉は、フォルダなら中の物の日付でも当たりにする（「去年の12月のスクショをまとめたフォルダ」）。
- 「A と同じ日に撮った B」「A の中の B」のような言い方は A と B に分け、A に近い上位 5 件から co_used を 2 回たどった点数（×0.5）＋ B との近さで並べる。
- 英数字だけの入力は、名前の読みのローマ字（CFStringTokenizer。ヘボン式・訓令式・長音を揃える）と 1 文字違いまで一致を見る（「seikyuu」「keycron」）。

### 設定（app/Sources/Raiden/SettingsWindow.swift、app/Sources/RaidenCore/Settings.swift）

メニューバーの「設定…」（⌘,）で開く。左の一覧で 4 つに分ける。見本は `build/Raiden --snapshot docs/ui` の `settings-*.png`（ダミーと初期値だけが写る）。
保存は `~/Library/Application Support/Raiden/settings.json`（`RaidenSettings`。フォルダは `~/` の形、項目ごとに読めなければ初期値、無ければ全部初期値。前の版の `folders`・`unloadMinutes` は読み捨てる）。

- **除外**: Spotlight の結果から外すフォルダ（初期値 ~/Library）と名前（`*` `?` のパターンも可。初期値は node_modules・.venv・build・*.log など）。隠しファイル・.app・パッケージの中はいつも外す。
  - 除外の初期値を増やしたときは、前の settings.json に増えた分だけを足す（`knownExcludeDefaults`・`knownExcludeFolderDefaults` に足した初期値を覚え、ユーザーが消した物は戻さない）。
- **一般**: 入力欄を開くキー（押して登録。システムのショートカットと重なれば知らせ、ほかのアプリが持っていて登録できなければ前のキーに戻す）、候補の最大件数、アプリとファイルの節の並び（自動／アプリ先／ファイル先）、透明度、ファイルのプレビューを出す、ログイン時に起動。
- **学習**（SettingsLearning.swift）: 選んだ結果を覚える オン・オフ、辞書の表（言い方 → アプリ / ファイル・フォルダ / 「#」の条件。足す・直す・消す）、保存した絞り込み（`#名前` → コマンド。足す・消す）、よく使う「#」の組み合わせ（検索の記録から。名前を付けて保存へ）、選んで開いた記録（言い方 → 物・回数・最後に使った日）と 1 件ずつの削除・全部消す。
- **記録**: 検索の記録を残す オン・オフ、残す日数（初期 90 日）、記録を全部消す、ログのフォルダを開く、最近の検索、見つからなかった言い方（「辞書に足す…」で行き先を選ぶと辞書に足す）。

### 記録（app/Sources/RaidenCore/SearchLog.swift, RaidenLog.swift）

どちらも手元だけに残し、外へは送らない。

- 検索の記録: raiden.sqlite の `search_log` 表。入力欄を開いてから閉じるまでを 1 行に、日時・入力の最終形・途中の打ち直し（`[{"q", "t": 開いてからの ms}]`）・出した候補（画面の並び順に種類・bundle id かパス・名前・点数・節）・選んだ物とその順位（教えた物は 0）・選ばずに閉じたか・「見つかりません」（全体・アプリの節・ファイルの節）・最後の検索にかかった時間。残す日数より古い行は起動時と 1 日 1 回消す。`raiden-eval --log-eval --store <コピー>` で、選んだ記録を今の並べ方で回し直して当時の順位と比べられる。
- 動作の記録: `~/Library/Logs/Raiden/raiden.log`（起動・アプリ一覧の作り直し・除外や設定の変更・エラー）。1MB で `raiden.1.log`〜`raiden.5.log` に回し、それより古いものと 30 日より古いものは消す。

### 絞り込みのコマンド（app/Sources/RaidenCore/QueryFilters.swift, FilterCompletion.swift, FilterMemory.swift, PhraseDictionary.swift, app/Sources/Raiden/FilterUI.swift, DictionaryLookup.swift, SettingsLearning.swift）

入力欄に `#kind ss #date 7d 請求書` のように書くと、当てはまらない物を候補から外す（QueryIntent の「昨日の」「PDFの」は言い方からの推測で点数を上下するだけだが、こちらは確実な絞り込み）。名前は Spotlight（kind / date / modified / created）と find / fd（#type #ext #path #name）にそろえた。

| コマンド | 別名 | 値 | 意味 |
|---|---|---|---|
| `#kind` | `#k` `#種類` | pdf, image, screenshot / ss, movie / video, music / audio, document / doc, spreadsheet / xls, presentation / ppt, md, text, code, archive / zip, 3d, folder, app（種類の名前でなければ拡張子） | 種類 |
| `#type` | `#t`（別名 `#app` = `#type app`、`#folder` = `#type d`、`#file` = `#type f`。`#t #app` も `#type app`） | f（ファイル）, d（フォルダ）, app（アプリ） | 対象 |
| `#ext` | `#e` `#拡張子` | pdf, docx, pdf,docx | 拡張子 |
| `#date` | `#日付` | today, yesterday, 7d, 2w, 3m, 1y, 2026, 2026-11, 2026-11-14, 11-14, 11-14..11-16, 今日・昨日・今週・先週・今月・先月・今年・去年（thisweek, lastweek, thismonth, lastmonth, thisyear, lastyear も） | 使った日・変更日・追加日・作成日のどれかが入る |
| `#modified` | `#m` `#変更日` | 同上 | 変更日だけ |
| `#created` | `#c` `#作成日` | 同上 | 作成日だけ |
| `#path` | `#p` `#in` `#場所` | Desktop, ~/Documents/仕事, "Obsidian Vault" | その下だけ（`~/` `/` で始まればその下、名前なら親フォルダの名前の一部、`a/b` ならパスの一部） |
| `#name` | `#n` `#名前` | 請求 | 名前にその文字を含む物だけ（文字の一致） |
| `#with` | `#w` `#一緒` | ~/Documents/見積書.pdf（ファイル 1 つ） | そのファイルと同じころに使った物 |
| `#near` | `#nr` `#近く` | ~/Project/raiden/README.md（ファイルかフォルダ 1 つ） | そのファイルと同じプロジェクトの物 |
| `#保存` | `#save` | 名前 | 今のチップに名前を付けて保存（絞り込みには使わない） |
| `#alias` | `#dict` `#辞書` | 言い方 | 辞書に足す（絞り込みには使わない。下の「辞書」） |
| `#<保存した名前>` | | | 保存した中身のコマンドに広げる（`#仕事のPDF` → `#ext pdf #path ~/Documents/仕事`） |

- 違うコマンドどうしは「かつ」、同じコマンドを 2 回・カンマ区切りは「または」。`#date` などを 2 回書いたら後の方で上書き（範囲は `11-14..11-16`）。`#with` `#near` も値は 1 つで後の方。
- アプリ（`#type app`）は `#kind`（アプリ以外）・`#ext`・`#date`・`#path`・`#with`・`#near` と一緒に使えない（入力欄の下に知らせる）。`#type d` と `#path`・`#date` は使える。
- コマンドを抜いた残りがふつうの曖昧検索。残りが空なら新しい順（使った日・変更日の新しい方）。「見つからない」の判定は残った物の中で行い、0 件なら「条件に合う物はありません」（近い日付の代わりは出さない）。
- コマンドと読むのは入力の先頭か空白の直後の「#」＋文字だけ。全角の「＃」も同じ（日本語入力のまま打てる）。「C#」「#1」は普通の文字。知らないコマンドや読めない値は絞り込まずに「#size は使えません」と出す。打っている途中（「#」「#da」「#date」「#date 2026-」「#仕事の」）は絞りも知らせもしない。

#### 検索の土台の担当が読む型（`QueryFilters.parse` の結果）

- `withPath: String?` / `nearPath: String?`: `#with` / `#near` の値。`~` `/` で始まれば `~` を広げた絶対パス（NFC）、そうでなければ書かれたとおり（名前）。`hasRelation` はどちらかがあるとき true。`isActive` に入り、`allowsApps` は false になる。
- `matches(_:)`（手元の一覧で当てはまるか）は `withPath` / `nearPath` を見ない。実行（Spotlight への問い合わせ）は土台の側で行う。
- チップは `Chip(command: .with, label: "一緒に使った: 見積書.pdf")`、`Chip(command: .near, label: "同じプロジェクト: 見積書.pdf")`。
- `saving` / `aliasing`: `#保存` / `#alias` の後ろの文字（入力欄が扱う。`pending` は "save" / "alias"）。
- 保存した名前（`#仕事のPDF`）は `parse` の中で中身に広がる（`SavedFilters` の置き場を引く）。Engine には広げた後と同じ結果が渡る。

#### 入力欄の動き

- 「#」: 先頭に保存した名前（`#仕事のPDF`、最大 4）とよく使う組み合わせ（`#ext pdf #path Downloads`、最大 3）、続けてコマンドの一覧（チップがあれば最後に `#保存`、いつも `#alias`）。組み合わせ・保存した名前を Enter で決めると、中身をまとめてチップにする（今のチップを含む組み合わせは残りだけ）。
- 「#date 」で値の候補（件数つき。ほかの条件の中で数え、0 件は下に回す）。↑↓ で選んで Enter / Tab、Esc で一覧だけ閉じる。打ちかけの値はゴーストテキストで補い → / Tab で決める。
- 値の候補の並び: よく使う値（検索の記録から）→ 件数のある値 → 0 件。`#ext` は手元に多い拡張子の順、`#path` / `#in` はよく使う場所（`#path` に書いた場所と選んだファイルの親フォルダ。☆と「よく使う」）→ 中身の多いフォルダ → 最近使ったフォルダ、`#with` / `#near` は最近選んだファイルと最近使った物（名前の一部で絞る。件数は出さない）。
- 値まで決まったコマンドはチップにして入力欄の下に並べる。チップの × で 1 つ、入力欄が空のときの Backspace で最後の 1 つ、⌘Backspace で全部を消す。チップの横に次に付けそうなコマンド（よく使う組み合わせの続き、`#kind ss` の後の `#date 今日`）を小さく出す。
- 「#」を打たない言葉からの候補: 「pdf」→ `#ext pdf`、「先週」→ `#date lastweek`、「画像」→ `#kind image`、「ダウンロード」→ `#path Downloads`、保存した名前・辞書の条件・よく使う場所の名前（`FilterSuggest`）。入力欄の下に「Tab で絞る」と薄く出し（最大 3。後ろの言葉から）、Tab / →（入力の最後で）で先頭を決めるか、押して決める。決めるとチップにして、入力からその言葉（と直後の「の」「で」「に」「から」）を外す。決めない限り絞らない。英数字の言葉は前後が英数字でないときだけ、同じコマンドがチップにあれば出さない。
- 保存: ⌘S（入力欄が「#保存 」になる）か `#保存 名前` → Enter で今のチップを保存する。同じ名前は上書き（入力欄に「置き換えました」）。名前はコマンドの名前・別名と同じもの、空白・`/ - . ,` を含むもの、文字で始まらないものは使えない。保存先は settings.json の `savedFilters`（`[{"name": "仕事のPDF", "commands": ["#ext pdf", "#path 仕事"]}]`）。設定の「学習」でも足す・消すができる。
- コマンドが 1 つでも効いているときは候補の上限（設定の最大件数）で切らず、当てはまる物を全部出す。パネルは画面の高さの 65% まで伸び、それ以上はスクロール。行は 200 件ずつ作り、↑↓ で選択行まで自動でスクロール。節の見出しに件数（「アプリ 133件」）。

#### 件数を出す口（`FilterSource`）

入力欄は件数を `FilterSource` からだけ聞く。アプリでは Spotlight で数える `SpotlightFilterSource`（上の「ファイルとフォルダ」）が答える。手元の一覧の `FilterContext` は確かめ（--test-filters）と見本で使う。

- `appCount`、`counts(_ cmd:, values:, within:, now:) -> [String: Int]?`（値ごとの件数。nil なら件数なしで候補だけ出す）、`total(_:) -> Int?`、`topExtensions(within:limit:)`、`topFolders(within:limit:)`、`recentFolders(limit:)`、`recentFiles(limit:)`（`#with` `#near` の候補）。使わない物は書かなくてよい（既定は nil / []）。
- 答えが後から届くときは、届いたら `FilterInput.sourceDidUpdate()` を呼ぶと一覧を出し直す。
- 口が無い・数えられないときは、`#ext` は覚えた値と決まった一覧、`#path` はよく使う場所か `~/Desktop` `~/Documents` `~/Downloads` で出す。

#### 覚えた使い方（`FilterMemory`）

`FilterMemory.build(from: store.searchLog(limit: 3000))` で search_log から作る（AppDelegate が起動時と記録を書くたびに裏で作り直す。Store には手を足していない）。1 回ごとに選んで開いたら 1、選ばずに閉じたら 0.4 を、30 日で半分になるように足す。

- `combos`: 使った「#」の組み合わせ（コマンドの順と別名をそろえる。`#e pdf #in Downloads` も `#ext pdf #path Downloads`）。点数 0.8 以上だけ。設定の「学習」にも出し、名前を付けて保存できる。
- `values`（よく使う値）、`folders`（よく使う場所）、`files`（最近選んだファイル）、`missed`（選ばずに閉じた・見つからなかった言い方。`#alias` の候補）。

#### 辞書（`PhraseDictionary`、`DictEntry`）

言い方 → アプリ / ファイル・フォルダ / 「#」の条件。settings.json の `dictionary` に入る（`[{"phrase": "黒い画面", "target": "app", "key": "/System/Applications/Utilities/Terminal.app", "name": "ターミナル"}]`。target は app / file / filter、key は .app のパス（bundle id でも引ける）・ファイルの絶対パス・コマンドの文字）。AppDelegate が設定を読んだ・変えたときに `PhraseDictionary.set` で置き場に入れる。

- 一致: `PhraseDictionary.matches(query)` が、入力（コマンドを抜き、大文字小文字・全角半角・空白をそろえる）にその言い方が含まれる行を、長い言い方から返す。
- アプリ・ファイルは候補の先頭の「辞書」の節に出し、下の節からは外す（`SearchPanelController.dictionaryCandidates` に AppDelegate が `DictionaryLookup.candidates` を渡す。無くなったアプリ・ファイルは出さない）。条件は「#」を打たない言葉からの候補に「辞書」として出す（決めたときだけ絞る）。
- 足し方（同じ言い方があれば聞かずに置き換え、「置き換えました」と出す。`PhraseDictionary.adding`）:
  - `#alias 言い方` → Enter: 入力欄が「「言い方」→ どれに？」の選ぶ状態になる。最初は言い方そのもので探した候補（アプリが先、続けてファイル・フォルダ）を出し、打てば名前で絞れる。↑↓ で選んで Enter で辞書に足し、入力欄に「黒い画面 → ターミナル を足しました」と出して元の入力とチップに戻る。Esc で取りやめ。`#alias ` の直後は、最近選ばずに閉じた・見つからなかった言い方を候補に出す。
  - 候補を選ぶときに ⌥Enter: 今の言葉（コマンドを抜いた物）→ 選んだ物を辞書に足してから開く。
  - 設定の「学習」の辞書の表（足す・直す・消す。行き先は「選ぶ…」でアプリ・ファイルを選ぶか、条件を書く）と、「記録」の見つからなかった言い方の「辞書に足す…」。
- 検索の土台の担当へ: 辞書の保存と読み出しは settings.json の `dictionary`（`RaidenSettings.dictionary`）にした。Store に移すなら `PhraseDictionary.set` に入れ直す所（AppDelegate.loadSettings / updateSettings）と `onAddDictionary` を差し替える。

#### 確かめ

- `raiden-eval --test-filters`: 解析・一覧・値の候補・ゴースト・件数（133 項目）に、候補の並び（口の差し替え）・よく使う組み合わせ（search_log を一時の Store に書いて読み直すまで）・保存した名前・言葉からの候補・`#with` `#near`・辞書の一致・`#alias` の 128 項目（`raiden-eval/FilterLearningEval.swift`）を足して 261 項目。モデルは読まない。
- `Raiden --test-focus`: 入力欄のフォーカスと打鍵（52 項目。言葉からの候補を Tab / → で決める、組み合わせを Enter、⌘⌫・チップの ×、⌘S で保存して `#名前` で呼ぶ、`#alias` の切り替え・足す・取りやめ・置き換え、⌥Enter、辞書の節、ファイルの行があるときだけ広げてプレビューを出す・設定で切る）。
- 見本は `docs/ui/option-*.png`（`option-combos.png`「#」の直後、`option-suggest.png` 言葉からの候補とチップ、`option-alias.png` 辞書の行き先を選ぶ状態）。

### ログイン時に起動（app/Sources/Raiden/LoginItem.swift）

初回起動で「アプリケーション」フォルダ（`scripts/build.sh --install` の `~/Applications/Raiden.app`）から起動していれば、ログイン時に起動するよう登録する。`build/Raiden.app` を試しに開いたときは登録しない。メニューバーの「ログイン時に起動」でオン・オフできる。

- まず `SMAppService.mainApp.register()`（システム設定の「ログイン項目」に Raiden が出る）。
- ad-hoc 署名（`codesign --sign -`）はビルドのたびに cdhash が変わり、システムの登録が前の版を指したまま「登録なし」に見えることがある。そのため起動のたびに状態を見て、オンのはずなのに有効でなければ登録し直す。
- それでも有効にならなければ（登録が失敗した・見つからない）、`~/Library/LaunchAgents/com.kosuke.raiden.plist`（`/usr/bin/open -a <Raiden.app>` を RunAtLoad）を置く。`open -a` なので、両方が効いても 2 つ目は立ち上がらない。SMAppService で有効になれば plist は消す。
- システム設定で切られている（承認待ち）ときは上書きしない。メニューでオンにしたときだけ、システム設定の「ログイン項目」を開く。

## 答え合わせ

```
build/raiden-eval [--miss]                    # アプリ 25 問・名前の一部 5 問・自作 13 問・他社 18 問（埋め込みなし）
build/raiden-eval --files --file-store <scratch の新しいファイル> [--miss]   # ファイル（Spotlight 版）
build/raiden-eval --test-filters              # 「#」の解析・候補
build/raiden-eval --test-spotlight            # 「#」と言い方 → Spotlight の条件、#near の根（~/Project の実物）、除外・種類・記録（80 項目）
build/raiden-eval --bench-spotlight --file-store <scratch>   # Mac 全域に問い合わせた時間、取り消し
build/raiden-eval --boot-bench --file-store <scratch>        # 起動から検索できるまでとメモリ
build/raiden-eval --settings-test --store <コピー>           # 設定・除外・前の版の DB の片付け・記録・ログ
```

自作アプリ・他社アプリ・ファイルの問題は私的な名前を含むので `~/Library/Application Support/Raiden/evals/` に置く（apps-own.json・apps-3p.json・files.json・parts/*.json）。`--store` / `--file-store` を渡さないと本物の raiden.sqlite を使うので、確かめは必ず scratch の新しいファイルかコピーで。

埋め込みをやめた前後（2026-11-20、1位 / 3位以内。当てにいく調整はしていない）:

| 問題 | 前（bge-m3） | 後（文字の一致） |
|---|---|---|
| アプリ 25 問 例なし・辞書なし | 12 / 18 | 9 / 10 |
| アプリ 25 問 例なし・辞書あり | 17 / 23 | 11 / 15 |
| アプリ 25 問 例あり | 21 / 24 | 11 / 15 |
| 名前の一部 5 問 | 5 / 5 | 5 / 5 |
| 自作 13 問 例なし / 例あり | 7 / 11・4 / 11 | 11 / 13・11 / 13 |
| 他社 18 問 例なし / 例あり | 14 / 17・13 / 16 | 7 / 12・7 / 12 |
| ファイル（答えのある問題。前 188 問・後 190 問） | 132 / 151 | 40 / 47 |

ファイルの種類ごと（1位 / 3位以内）: file 21/24 → 4/8、folder 18/24 → 5/6、time 20/25 → 12/12、type 23/24 → 12/13、relation 15/17 → 0/1、partial 19/21 → 4/4、english 16/16 → 3/3。答え無し 40 問は 34 問を「見つからない」にした。

- アプリで落ちたのは、名前にも辞書の言葉にも文字が重ならない言い方（「黒い画面でコマンド打つやつ」→ ターミナル、「顔を見ながら電話」→ FaceTime、「世界地図見るやつ」→ マップ）。記録（例あり）は答え合わせの言い方と文字が重ならないので効かない。自作は README の材料の文字が当たり、前より上がった。
- ファイルで落ちたのは、説明の言い方で名前に無い言葉を使う問題（「大阪で泊まった宿の領収書」→ ホテルフクラシア大阪ベイ.pdf は「大阪」で引けるが「領収書」の方が多く当たる）と、つながり（relation）。時間・種類は「#」と同じ条件になるので残った。

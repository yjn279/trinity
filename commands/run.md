---
description: "Planner → Generator → Evaluator のハーネスパイプラインを実行する。使用例 `/trinity:run <要件>` または `/trinity:run --max-iter=5 <要件>`。"
argument-hint: "[--max-iter=N] <1〜4文の要件>"
---

# /trinity:run — 3エージェント・ハーネスパイプライン

ハーネスを取り回すスラッシュコマンドである。Plannerが要件を計画に展開し、Generatorが隔離された worktree で実装してコミットし、Evaluatorが独立に判定する。判定が PASS になるか、`max_iter` に到達するまで繰り返す。最終 PASS 後、worktree のブランチを push して PR を作成する。

## 引数

生の引数は `$ARGUMENTS` で受け取る。次の手順で解釈する。

`$ARGUMENTS` の先頭が `--max-iter=N`（N は正の整数）であれば、`MAX_ITER = N` とし、そのトークンを取り除く。先頭が一致しない場合は `MAX_ITER = 15`（既定値）を使う。

残りを「要件」として扱う。要件が空ならユーザーに1〜4文の要件を求めて停止する。先には進めない。

## プリフライト（hook 担当）

`UserPromptSubmit` hook が `/trinity:run` を検出したとき次を強制する。あなたはこれを再実装しない。

- カレントが git リポジトリであること
- ワーキングツリーが clean であること（汚れていれば prompt がブロックされる）
- 現在のブランチを stderr に表示する

このため、本コマンドが起動した時点で「現在のブランチが clean なベースライン」であることが保証されている。これを `BASE_BRANCH` として保持する。

```shell
BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

## run ディレクトリと worktree の作成

要件からスラッグを生成し、run ディレクトリと隔離 worktree を作る。スラッグは2〜5語の英字 kebab-case にする（例: 「ユーザー設定ページにテーマトグルを追加する」→ `add-theme-toggle`）。

```shell
TS=$(date -u +%Y%m%dT%H%M%SZ)
SLUG=<要件から生成した英字 kebab-case>
RUN_DIR="$(pwd)/.trinity/${TS}-${SLUG}"
WORKTREE_DIR="${RUN_DIR}/worktree"
BRANCH="trinity/${TS}-${SLUG}"
mkdir -p "$RUN_DIR"
git worktree add -b "$BRANCH" "$WORKTREE_DIR" "$BASE_BRANCH"
printf '=== %s run started on %s (base=%s) ===\n' "${TS}-${SLUG}" "${BRANCH}" "${BASE_BRANCH}" >> .trinity/trinity.log
```

同一タイムスタンプで衝突した場合は `SLUG` の末尾に `-2` `-3` などを付ける。

`$RUN_DIR` と `$WORKTREE_DIR` と `$BRANCH` と `$BASE_BRANCH` を以降の全段に絶対パスで渡す。

## パイプライン（n = 1 .. MAX_ITER のループ）

### Planner

`trinity:planner` サブエージェントを次の入力で起動する。

- 要件（原文ママ）
- `Iteration: <n>`
- `RUN_DIR: <絶対パス>`
- `WORKTREE_DIR: <絶対パス>`（実装対象のコードはこの中にある）
- `n > 1` の場合は、直前の評価レポートが `${RUN_DIR}/eval-<n-1>.md` にある旨を伝える

返却された計画ファイルパス（必ず `${RUN_DIR}/plan.md`）を保持する。Plannerが確認のための質問をユーザーに投げた場合は、その内容をユーザーに見せて停止する。

### Generator

Generator フェーズはチャンク分割で複数回 `trinity:generator` サブエージェントを順次起動する。各チャンクが独立な Claude CLI ターン予算を持つことで、出力上限超過を回避する。

#### チャンク列の決定（plan.md のパース）

Planner が書き出した `${RUN_DIR}/plan.md` の `## 影響範囲` セクションを次の手順で決定的にパースし、チャンク列を組み立てる。

1. `## 影響範囲` セクション配下に `### チャンク N: ...`（N は 1 以上の整数）の H3 サブセクションが 1 個以上存在するか確認する。存在すれば各サブセクションを 1 チャンクとして扱う。各チャンクの「ファイル群（ChunkFiles）」は、そのサブセクション内に箇条書き・コードフェンス・本文 `path` 形式で列挙されたファイルパスから取り出す。
2. `### チャンク N: ...` サブセクションが存在しなければ、`## 影響範囲` テーブル全体を 1 チャンクとして扱う。テーブルの 1 列目（`ファイル / モジュール`）から `path:line` の `path` 部分を抽出してファイル群とする（列順は `ファイル / モジュール | 変更種別 | 理由` を前提とする）。
3. パース結果が空（ファイル群が 0 件）の場合は停止し、`${RUN_DIR}/plan.md` の `## 影響範囲` を確認するようユーザーに報告する。

```shell
# チャンク総数の計算（例: bash/awk による H3 カウント）
CHUNK_TOTAL=$(awk '/^## 影響範囲/{in_sec=1} in_sec && /^### チャンク [0-9]+:/{count++} /^## [^#]/{if(in_sec && !/^## 影響範囲/)in_sec=0} END{print (count>0?count:1)}' "${RUN_DIR}/plan.md")
```

> **Planner への注記**: Planner は `## 影響範囲` 配下に `### チャンク N: <タイトル>` サブセクションを任意で書くことで、Orchestrator のチャンク分割動作を制御できる。`agents/planner.md` 本体は変更しない。

#### チャンクごとの順次起動

チャンク総数 `M` を決定したら、`i = 1..M` の順で `trinity:generator` サブエージェントを**順次**起動する（並列起動はしない）。

各チャンク `i` の起動入力:

- `RUN_DIR: <絶対パス>`
- `WORKTREE_DIR: <絶対パス>`
- `BRANCH: <ブランチ名>`
- `Iteration: <n>`
- `ChunkIndex: <i>`
- `ChunkTotal: <M>`
- `ChunkFiles: <i 番目のチャンクのファイル列、カンマ区切り>`

各チャンクは `${RUN_DIR}/gen-<n>-chunk-<i>.md` にレポートを書き、その絶対パスを返す。Orchestrator はそのパスを保持する。

#### 停止条件

あるチャンク `i` で Generator が「検証失敗 → 自力修正不能 → コミット未作成」となった場合、後続チャンク（`i+1..M`）を起動せず Orchestrator はループを停止し、ユーザーに次の情報を報告する。

- 失敗したチャンク番号 `i` / `M`
- 最後に書き出されたレポートパス（`${RUN_DIR}/gen-<n>-chunk-<i>.md`）
- 失敗内容

存在しないコミットを Evaluator に渡してはいけない。

#### Evaluator への引き渡し

全チャンク成功時、Orchestrator は次のコマンドでイテレーション内最終コミット SHA を取得する。

```shell
LAST_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
```

Evaluator にはこの 1 つの SHA と `ChunkTotal: <M>` を渡す。Evaluator 側で `ChunkTotal > 1` のときに `git -C "${WORKTREE_DIR}" log --oneline -n <ChunkTotal>` で中間コミットを遡る契約になっているため、各チャンクの中間コミット SHA を個別に渡す必要はない。

### Evaluator

`trinity:evaluator` サブエージェントを次の入力で起動する。

- `RUN_DIR: <絶対パス>`
- `WORKTREE_DIR: <絶対パス>`
- `Iteration: <n>`
- コミットSHA（イテレーション内最終コミット。`ChunkTotal > 1` のとき Evaluator が `git log -n <ChunkTotal>` で中間コミットを遡る）
- `ChunkTotal: <M>`
- Generatorの検証レポート（最終チャンクのレポートパス `${RUN_DIR}/gen-<n>-chunk-<M>.md`）

返却された評価レポートのパス（必ず `${RUN_DIR}/eval-<n>.md`）と判定（PASS / NEEDS_REVISION / FAIL）を保持する。

### 分岐

PASS の場合はループを抜けて「最終化」セクションに進む。

NEEDS_REVISION で `n < MAX_ITER` の場合はループを継続する。Plannerは次の周回で評価レポートを受け取り、計画ファイルを新規作成せず上書きする。

FAIL の場合も同じく次の周回に進む。Plannerはより踏み込んだ再計画を行う。

`n == MAX_ITER` で PASS になっていない場合は最終化をスキップし、最新の評価レポートのパスと未解決の指摘を表示して停止する。終了行をログに書く。

```shell
printf '=== %s run ended: %s at iter %d/%d ===\n' "${TS}-${SLUG}" "${VERDICT}" "$n" "$MAX_ITER" >> .trinity/trinity.log
```

## 最終化（PASS のときだけ）

PASS で抜けたら次を順に行う。

1. ログに完了行を書く。

```shell
printf '=== %s run ended: PASS at iter %d ===\n' "${TS}-${SLUG}" "$n" >> .trinity/trinity.log
```

2. worktree のブランチを origin に push する。失敗はネットワーク要因のときのみ最大4回 exponential backoff で再試行する（2s, 4s, 8s, 16s）。それ以外の失敗（権限・ブランチ保護など）はそのまま停止してユーザーに報告する。

```shell
git -C "$WORKTREE_DIR" push -u origin "$BRANCH"
```

3. PR を作成する。`/trinity:run` の起動自体がパイプライン全体（PR作成を含む）への明示的な許可なので、ユーザー確認は取らずに進める。

PR の作成には GitHub MCP ツールを使う。スキーマが未ロードなら最初に `ToolSearch query="select:mcp__github__create_pull_request"` で読み込む。リポジトリ owner/repo は `git -C "$WORKTREE_DIR" remote get-url origin` から取り出す。

PR のタイトルは `${RUN_DIR}/plan.md` の先頭 H1 をそのまま使う。70 文字を超えるなら冒頭で切り詰める。

PR の本文は次の形にする。`.trinity/` は gitignore されておりレビュアーから見えないため、計画と判定の核心は本文に埋め込む。

```
## 概要
<plan.md の "目的" セクション本文をそのまま貼る>

## 受け入れ基準
<plan.md の "受け入れ基準" セクションを箇条書きでそのまま貼る>

## Trinity 実行サマリ
- Run: <RUN_DIR を repo ルートからの相対パスで>
- Iterations: <n>/<MAX_ITER>
- Final verdict: PASS
- Final commit: <短縮SHA>

## 判定根拠（最終 Evaluator レポートからの抜粋）
<eval-<n>.md の "判定" セクションをそのまま貼る>
```

base は `$BASE_BRANCH`、head は `$BRANCH` とする。

## ユーザーへの出力

ループ終了時に次の形式でちょうど印字する。最終化を実施した場合は最後に PR 行を加える。

```shell
Trinity result: <PASS | NEEDS_REVISION at iter <n> | FAIL at iter <n>>
RunDir:  <RUN_DIR>
Branch:  <BRANCH> (base: <BASE_BRANCH>)
Plan:    <RUN_DIR>/plan.md
Commit:  <最後のコミットSHA>
Eval:    <RUN_DIR>/eval-<n>.md
Iters:   <n>/<MAX_ITER>
PR:      <PR URL>            # PASS のときのみ
```

その後に2〜3文の平易な要約を添える。

続けて、終了種別（PASS / NEEDS_REVISION / FAIL、および `n == MAX_ITER` での未解決停止）にかかわらず毎回、次の案内を1〜2行で出力する。

> trinity プラグイン自体のバグや仕様の要望があれば、ぜひ https://github.com/yjn279/trinity/issues へ起票してください。

それ以上は書かない。

## オーケストレーター（あなた）への制約

サブエージェントは並列ではなく直列に呼び出す。各段は前段の出力に依存するためである。Generator の同一イテレーション内チャンクも同様に直列で起動する。

段と段のあいだで、コードを自分で読んだり編集したりしない。受け渡しは `RUN_DIR` `WORKTREE_DIR` `BRANCH` のパスとコミットSHAだけにする。各エージェントが成果物（ファイル）から動くという原則がハーネスの本質である。

エージェントの出力を要約して次のエージェントに渡さない。`RUN_DIR` を渡し、次のエージェントに自分で読ませる。Evaluatorに必要な独立性はこれで担保される。

worktree の後始末は行わない。`.trinity/` は gitignore されており、worktree は監査ログとして残す。ユーザーが不要と判断したときに `git worktree remove` する。

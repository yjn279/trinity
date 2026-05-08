---
description: "Planner → Generator → Evaluator のハーネスパイプラインを実行する。最終 PASS 後は push と PR 作成を行い、ユーザー承認のもとでマージとお片付けまでを完結させる。使用例 `/trinity:run <要件>` または `/trinity:run --max-iter=5 <要件>`。"
argument-hint: "[--max-iter=N] <1〜4文の要件>"
---

# /trinity:run — 3エージェント・ハーネスパイプライン

ハーネスを取り回すスラッシュコマンドである。Plannerが要件を計画に展開し、Generatorが隔離された worktree で実装してコミットし、Evaluatorが独立に判定する。判定が PASS になるか、`max_iter` に到達するまで繰り返す。最終 PASS 後、worktree のブランチを push して PR を作成し、ユーザー承認のもとでマージとお片付けまでを行う。

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

`trinity:generator` サブエージェントを次の入力で起動する。

- `RUN_DIR: <絶対パス>`
- `WORKTREE_DIR: <絶対パス>`
- `BRANCH: <ブランチ名>`
- `Iteration: <n>`

Generator は `${RUN_DIR}/plan.md` を読み、`n > 1` の場合は `${RUN_DIR}/eval-<n-1>.md` も読む。コードの読み書きとコミットは `${WORKTREE_DIR}` の中だけで行う。返却された検証レポートとコミットSHAを保持する。Generatorが検証失敗で自力修正もできずコミットを作れなかった場合は、停止して失敗内容をユーザーに報告する。存在しないコミットを Evaluator に渡してはいけない。

### Evaluator

`trinity:evaluator` サブエージェントを次の入力で起動する。

- `RUN_DIR: <絶対パス>`
- `WORKTREE_DIR: <絶対パス>`
- `Iteration: <n>`
- コミットSHA
- Generatorの検証レポート

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

PASS で抜けたら次の4ステップを順に行う。

### ステップ1: ログ書き込み

```shell
printf '=== %s run ended: PASS at iter %d ===\n' "${TS}-${SLUG}" "$n" >> .trinity/trinity.log
```

### ステップ2: push

worktree のブランチを origin に push する。失敗はネットワーク要因のときのみ最大4回 exponential backoff で再試行する（2s, 4s, 8s, 16s）。それ以外の失敗（権限・ブランチ保護など）はそのまま停止してユーザーに報告する。

```shell
git -C "$WORKTREE_DIR" push -u origin "$BRANCH"
```

### ステップ3: PR 作成

`/trinity:run` の起動自体がパイプライン全体（PR 作成を含む）への明示的な許可なので、ユーザー確認は取らずに進める。

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

base は `$BASE_BRANCH`、head は `$BRANCH` とする。PR 作成レスポンスから PR 番号（`PR_NUMBER`）と URL（`PR_URL`）を取り出して保持する。

### ステップ4: マージ確認（`AskUserQuestion`）

PR 作成直後に 1 回だけ `AskUserQuestion` を呼ぶ。ユーザーへの最終出力より前に実行する。

- 質問文: `PR #<PR_NUMBER> (<PR_URL>) を作成しました。マージしてお片付けまで進めますか？`
- 選択肢:
  1. `マージしてお片付け (Recommended)` — リモートで PR をマージし、ローカル worktree と branch を削除する
  2. `PR は残す（マージしない）` — マージもお片付けもしない。ユーザーが後で手動で扱う
  3. `Other` — 自由入力。上記いずれかに解釈できないときは「PR は残す」として扱う

回答が「マージしてお片付け」の場合のみ、以下の「マージ実行」と「お片付け」を行う。それ以外（否認・Other）の場合はどちらも行わない。

## マージ実行（承認時のみ）

GitHub MCP の `mcp__github__merge_pull_request` を使う。スキーマが未ロードなら `ToolSearch query="select:mcp__github__merge_pull_request"` で読み込む。owner/repo/PR 番号は PR 作成レスポンスから引き継ぐ。マージ方式は `squash` に固定する。

マージ失敗（コンフリクト、ブランチ保護違反、必須レビュー未完了など）は再試行せずに停止し、エラー文言と `PR_URL` をユーザーに伝える。お片付けには進まない。

## お片付け（マージ成功時のみ）

次の手順を順に実行する。失敗したら以降をスキップし、残っている操作をユーザーに伝える。

**1. リモートブランチの削除とローカルへの反映**

GitHub の PR マージ後にリモートブランチを削除する。`merge_pull_request` がリモートブランチを自動削除しない場合は次を実行する。

```shell
git -C "$WORKTREE_DIR" push origin --delete "$BRANCH"
```

その後、起動側リポジトリのリモート追跡参照を更新する。

```shell
git -C "$(pwd)" fetch --prune origin
```

**2. worktree の削除**

worktree ディレクトリを削除する。`--force` なしで失敗した場合（dirty な状態など）は `--force` 付きで再実行する。それでも失敗したらここで停止し、残りの操作をユーザーに伝える。

```shell
git -C "$(pwd)" worktree remove "$WORKTREE_DIR"
# dirty で失敗した場合:
git -C "$(pwd)" worktree remove --force "$WORKTREE_DIR"
```

**3. ローカルブランチの削除**

```shell
git -C "$(pwd)" branch -D "$BRANCH"
```

**4. 監査ログの保持**

`.trinity/<run>/` ディレクトリのうち `plan.md` `eval-*.md` `trinity.log` は削除しない。worktree ディレクトリのみ消える。

## ユーザーへの出力

ループ終了時に次の形式でちょうど印字する。

```
Trinity result: <PASS | NEEDS_REVISION at iter <n> | FAIL at iter <n>>
RunDir:  <RUN_DIR>
Branch:  <BRANCH> (base: <BASE_BRANCH>)
Plan:    <RUN_DIR>/plan.md
Commit:  <最後のコミットSHA>
Eval:    <RUN_DIR>/eval-<n>.md
Iters:   <n>/<MAX_ITER>
PR:      #<PR_NUMBER> <PR_URL>                        # PASS のときのみ
Merge:   <merged | declined | failed: <理由>>          # PASS のときのみ
Cleanup: <done | skipped | partial: <残っている操作>>   # PASS のときのみ
```

NEEDS_REVISION / FAIL のまま MAX_ITER に到達した場合は、push・PR 作成・マージ確認・お片付けのいずれも行わない。`PR:`・`Merge:`・`Cleanup:` 行は出力しない。

その後に2〜3文の平易な要約を添える。否認時またはお片付けが partial になった場合は、ユーザーが手動で実行すべきコマンドをその場に表示する。それ以上は書かない。

## オーケストレーター（あなた）への制約

サブエージェントは並列ではなく直列に呼び出す。各段は前段の出力に依存するためである。

段と段のあいだで、コードを自分で読んだり編集したりしない。受け渡しは `RUN_DIR` `WORKTREE_DIR` `BRANCH` のパスとコミットSHAだけにする。各エージェントが成果物（ファイル）から動くという原則がハーネスの本質である。

エージェントの出力を要約して次のエージェントに渡さない。`RUN_DIR` を渡し、次のエージェントに自分で読ませる。Evaluatorに必要な独立性はこれで担保される。

承認時のみ worktree の後始末を行う。否認時は `.trinity/` が gitignore されており、worktree は監査ログとして残る。否認または partial 状態のときは、次のコマンドをユーザーに示す。

```shell
git -C "$(pwd)" worktree remove "$WORKTREE_DIR"   # worktree 削除
git -C "$(pwd)" branch -D "$BRANCH"               # ローカルブランチ削除
git -C "$(pwd)" fetch --prune origin              # リモート追跡参照の更新
```

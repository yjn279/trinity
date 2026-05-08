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

PASS で抜けたら次を順に行う。

1. ログに完了行を書く。

```shell
printf '=== %s run ended: PASS at iter %d ===\n' "${TS}-${SLUG}" "$n" >> .trinity/trinity.log
```

2. worktree のブランチを origin に push する。失敗はネットワーク要因のときのみ最大4回 exponential backoff で再試行する（2s, 4s, 8s, 16s）。それ以外の失敗（権限・ブランチ保護など）はそのまま停止してユーザーに報告する。

```shell
git -C "$WORKTREE_DIR" push -u origin "$BRANCH"
```

3. PR を作成する。`/trinity:run` の起動自体がパイプライン全体（push と PR 作成を含む）への明示的な許可なので、ここまではユーザー確認を取らずに進める。ただしマージは破壊的な操作なので、PR 作成後に別途ユーザー確認を取る。

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

`create_pull_request` のレスポンスから `number` フィールド（PR 番号）と `html_url` フィールド（PR URL）を保持する。

4. PR 番号と URL をユーザーに見せる。次の形式で印字する。

```
PR #<番号> が作成されました: <PR URL>
```

5. `AskUserQuestion` を 1 回だけ呼び出し、マージするかどうかを尋ねる。

質問文には次の情報を含める。
- PR のタイトルと番号（`#<番号>`）
- PR URL
- マージ後に行うお片付けの内容（worktree ディレクトリの撤去とローカルブランチの削除）

選択肢は次の3つを順に並べる。

1. `Squash and merge, then clean up (Recommended)` — GitHub の squash merge を実行しお片付けする。
2. `Create a merge commit, then clean up` — 通常の merge commit を作成しお片付けする。
3. `Leave the PR open` — マージせず終了。お片付けもしない。

6. ユーザーの回答に応じて次のとおり分岐する。

**選択肢 1 または 2 が選ばれた場合（マージ実行）:**

GitHub MCP の `merge_pull_request` 相当ツールを呼び出してマージする。`merge_method` は選択肢 1 なら `squash`、選択肢 2 なら `merge` を渡す。

マージが成功した場合は次のログを書く。

```shell
printf '=== %s merged: %s at #%s ===\n' "${TS}-${SLUG}" "<squash|merge>" "<PR番号>" >> .trinity/trinity.log
```

マージが失敗した場合（コンフリクト、ブランチ保護、CI 未通過など）はその旨をユーザーに報告し、お片付けをスキップして終了する。PR はそのまま残す。リトライしない。次のログを書く。

```shell
printf '=== %s merge failed: %s ===\n' "${TS}-${SLUG}" "<失敗理由>" >> .trinity/trinity.log
```

**マージ成功後のお片付け:**

お片付けは次の順番で行う。途中のステップが失敗しても、残りのステップを可能な限り続行する。失敗の内容は記録しておき、最終出力の `Cleanup:` 行に反映する。

1. リモートブランチを削除する。GitHub の「マージ後に自動でブランチを削除」設定が有効な場合はすでに削除済みの可能性があるため、エラーは無視する。

```shell
git push origin --delete "$BRANCH"
```

2. worktree 側のチェックアウトをデタッチ状態にして、`git worktree remove` がエラーなく通るようにする。

```shell
git -C "$WORKTREE_DIR" checkout --detach
```

3. worktree を撤去する。

```shell
git worktree remove "$WORKTREE_DIR"
```

4. ローカルブランチを削除する。

```shell
git branch -D "$BRANCH"
```

5. `${RUN_DIR}/plan.md` と `${RUN_DIR}/eval-*.md` は**削除しない**。監査ログとして残す。

お片付けが完了したら次のログを書く。

```shell
printf '=== %s cleaned up worktree and branch ===\n' "${TS}-${SLUG}" >> .trinity/trinity.log
```

お片付けの途中で失敗が生じた場合は `Cleanup: partial: <details>` として報告する。

**選択肢 3 が選ばれた場合（マージしない）:**

PR をそのまま残し、お片付けはせずに終了する。次のログを書く。

```shell
printf '=== %s merge declined by user ===\n' "${TS}-${SLUG}" >> .trinity/trinity.log
```

**「Other」自由入力が返された場合:**

3つの選択肢のいずれにも該当しない入力を受けた場合は、安全側（マージしない・お片付けしない）に倒して終了する。

**PR が作成されなかった経路（`MAX_ITER` 到達で PASS なし、Generator/Evaluator 失敗、push 失敗など）では、マージ確認は発火しない。**

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
PR:      #<番号> <PR URL>                      # PASS のときのみ
Merge:   <squash | merge | declined | failed: <reason>>  # PASS のときのみ
Cleanup: <done | skipped (PR open) | partial: <details>> # PASS のときのみ
```

`PR:` `Merge:` `Cleanup:` の3行は PASS で PR が作成された場合のみ出力する。`MAX_ITER` 到達で PASS なし、Generator/Evaluator 失敗、push 失敗など「PR が作られない経路」ではこれらの行は出さない。

その後に2〜3文の平易な要約を添える。それ以上は書かない。

## オーケストレーター（あなた）への制約

サブエージェントは並列ではなく直列に呼び出す。各段は前段の出力に依存するためである。

段と段のあいだで、コードを自分で読んだり編集したりしない。受け渡しは `RUN_DIR` `WORKTREE_DIR` `BRANCH` のパスとコミットSHAだけにする。各エージェントが成果物（ファイル）から動くという原則がハーネスの本質である。

エージェントの出力を要約して次のエージェントに渡さない。`RUN_DIR` を渡し、次のエージェントに自分で読ませる。Evaluatorに必要な独立性はこれで担保される。

worktree の後始末は「マージ確認でユーザーが承認した場合のみ」行う。承認された場合はハーネスが自動でお片付けする（手順は「最終化」セクションを参照）。ユーザーが `Leave the PR open` を選んだ場合は worktree とブランチをそのまま残す。`.trinity/<run>/plan.md` と `.trinity/<run>/eval-*.md` は承認・拒否にかかわらず監査ログとして保持する。

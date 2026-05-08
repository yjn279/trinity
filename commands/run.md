---
description: "Planner → Generator → Evaluator のハーネスパイプラインを実行する。最終 PASS 後は push と PR 作成を行い、ユーザー承認のもとでマージとクリーンアップまでを完結させる。使用例 `/trinity:run <要件>` または `/trinity:run --max-iter=5 <要件>`。"
argument-hint: "[--max-iter=N] <1〜4文の要件>"
---

# /trinity:run — 3エージェント・ハーネスパイプライン

ハーネスを取り回すスラッシュコマンドである。Planner が要件を計画に展開し、Generator が隔離された worktree で実装してコミットし、Evaluator が独立に判定する。判定が PASS になるか、`max_iter` に到達するまで繰り返す。最終 PASS 後、worktree のブランチを push して PR を作成し、ユーザー承認のもとでマージとクリーンアップまでを行う。

## 使うスキル

このコマンドの実行手順は次の 3 スキルに分割されている。各フェーズで該当スキルを参照し、その手順に従う。スキル本文を要約せず、書かれている規範をそのまま守ること。

- `git-worktree` — 起動直後、要件文と BASE_REF を渡して隔離 worktree を作成する。TS / SLUG / BRANCH / RUN_DIR / WORKTREE_DIR はスキルが返す
- `git-pull-request` — PASS 後の origin への push と PR 作成を一連フローで実行し、`PR_NUMBER` / `PR_URL` を返す
- `git-merge` — 承認が取れている前提で squash マージと worktree/branch/追加パスのクリーンアップを行う

## 引数

生の引数は `$ARGUMENTS` で受け取る。次の手順で解釈する。

- 先頭が `--max-iter=N`（N は正の整数）であれば `MAX_ITER = N` とし、そのトークンを取り除く
- 先頭が一致しない場合は `MAX_ITER = 15`（既定値）
- 残りを「要件」として扱う。要件が空ならユーザーに 1〜4 文の要件を求めて停止する
- `MAX_ITER` は 1 未満を受け付けない。0 以下なら停止して報告する

## プリフライト（hook 担当）

`UserPromptSubmit` hook が `/trinity:run` を検出したとき次を強制する。あなたはこれを再実装しない。

- カレントが git リポジトリであること
- ワーキングツリーが clean であること（汚れていれば prompt がブロックされる）
- 現在のブランチを stderr に表示する

このため、本コマンドが起動した時点で「現在のブランチが clean なベースライン」であることが保証されている。

## ハーネス規範（全フェーズで守る不変ルール）

これらのルールは全フェーズで例外なく適用する。

### 直列で呼ぶ

サブエージェントは並列ではなく直列に呼び出す。各段は前段の成果ファイル（`plan.md` / コミット / `eval-<n>.md`）に依存している。Evaluator はコミット SHA を入力に取るので、Generator が終わってからしか起動できない。並列化すると存在しない SHA を渡してしまう。

### 段と段のあいだでコードに触らない

オーケストレーターが `Read` `Edit` `Bash` で `${WORKTREE_DIR}` 内のコードを読んだり編集したりしてはいけない。例外なく禁止する。触ってよいのは次だけである。

- `${RUN_DIR}` 配下のファイル名一覧の確認（読まない、開かない）
- `.trinity/trinity.log` への開始行・終了行の追記
- `git -C "$WORKTREE_DIR" rev-parse` などの非破壊・非読取の git メタ問い合わせ
- `git -C "$WORKTREE_DIR" push`（最終化のみ）

### エージェント出力を要約しない

Generator の検証レポートを圧縮して Evaluator に渡してはいけない。Generator が書いたレポート本文をそのまま渡す。各段への入力は次のとおり最小化する。

- Planner: 要件文、`Iteration`、`RUN_DIR`、`WORKTREE_DIR`、必要なら `eval-<n-1>.md` の存在告知
- Generator: `RUN_DIR`、`WORKTREE_DIR`、`BRANCH`、`Iteration`
- Evaluator: `RUN_DIR`、`WORKTREE_DIR`、`Iteration`、コミット SHA、Generator の検証レポート

### 最終出力以外を喋らない

ループ中、各段の途中報告をユーザーに垂れ流さない。最終出力フォーマット 1 ブロック + 2〜3 文の要約だけを返す。例外は次の 4 つだけである。

- Planner が `AskUserQuestion` で確認を投げた → そのまま見せて停止
- Generator がコミットを作れずに停止 → 失敗内容を見せて停止
- push に恒久失敗が起きた → 原文を見せて停止（`git-pull-request` 参照）
- マージ可否確認 `AskUserQuestion` → ユーザー回答を待つ（最終出力より前）

## 実行手順

1. **準備**: `git-worktree` スキルを呼んで隔離 worktree を作成する

   次のパラメータを渡す。

   - `REQUIREMENT` = 要件文（原文ママ）
   - `BASE_REF` = `$(git rev-parse --abbrev-ref HEAD)`（現在のブランチ）
   - `REPO_ROOT` = `$(pwd)`（起動側リポジトリのルート）
   - `LOG_PATH` = `$(pwd)/.trinity/trinity.log`

   スキルから次の値を受け取り、以降のすべてのフェーズで使う。

   - `TS` — タイムスタンプ
   - `SLUG` — 確定した slug
   - `BRANCH` — ブランチ名（`trinity/<TS>-<SLUG>` 形式）
   - `RUN_DIR` — run ディレクトリの絶対パス
   - `WORKTREE_DIR` — worktree の絶対パス

   `BASE_BRANCH` = スキルに渡した `BASE_REF` の値を保持する。

2. **ループ**: `n = 1 .. MAX_ITER` で次を順に呼ぶ。並列にしない。

   - **Planner**: `trinity:planner` サブエージェントを起動。要件（原文ママ）、`Iteration: <n>`、`RUN_DIR`、`WORKTREE_DIR`、`n > 1` なら直前 `eval-<n-1>.md` の存在告知を渡す。`${RUN_DIR}/plan.md` を書く（再計画時は上書き）。Planner が `AskUserQuestion` を投げた場合はそのまま見せて停止する。
   - **Generator**: `trinity:generator` サブエージェントを起動。`RUN_DIR`、`WORKTREE_DIR`、`BRANCH`、`Iteration` を渡す。検証レポートとコミット SHA を保持する。コミットを作れなかった場合はループを停止して失敗内容をユーザーに報告する。存在しないコミットを Evaluator に渡してはいけない。
   - **Evaluator**: `trinity:evaluator` サブエージェントを起動。`RUN_DIR`、`WORKTREE_DIR`、`Iteration`、コミット SHA、Generator の検証レポートをそのまま渡す。`${RUN_DIR}/eval-<n>.md` と判定（`PASS` / `NEEDS_REVISION` / `FAIL`）を受け取る。

3. **判定に応じた分岐**:

   | 判定 | 残りイテレーション | 動作 |
   | --- | --- | --- |
   | `PASS` | — | ループ脱出。以降の最終化フェーズに進む |
   | `NEEDS_REVISION` | `n < MAX_ITER` | 続行。Planner は次周回で `plan.md` を**上書き** |
   | `FAIL` | `n < MAX_ITER` | 続行。Planner はより踏み込んだ再計画を行う |
   | `NEEDS_REVISION` または `FAIL` | `n == MAX_ITER` | 最終化をスキップ。最新の評価レポートのパスと未解決の指摘を表示して停止 |

   `FAIL` を「だいたい OK」と解釈してループを抜けない。`MAX_ITER` を黙って延長しない。

4. **PASS のとき**: 次を順に実行する

   **a. `git-pull-request` を呼ぶ**

   次のパラメータを渡す。

   - `WORKTREE_DIR` = `$WORKTREE_DIR`
   - `BRANCH` = `$BRANCH`
   - `BASE_BRANCH` = `$BASE_BRANCH`
   - `PLAN_PATH` = `${RUN_DIR}/plan.md`
   - `EVAL_PATH` = `${RUN_DIR}/eval-<n>.md`（最終イテレーションの eval ファイル）
   - `RUN_META` = 次の情報をまとめたもの
     - `Run: <RUN_DIR をリポジトリルートからの相対パスで>`
     - `Iterations: <n>/<MAX_ITER>`
     - `Final verdict: PASS`
     - `Final commit: <短縮SHA>`

   返ってきた `PR_NUMBER` / `PR_URL` を保持する。

   **b. マージ可否確認（`AskUserQuestion` — 本コマンドの責務）**

   `AskUserQuestion` を 1 回目として呼ぶ。`AskUserQuestion` の合計呼び出し回数は最大 2 回（マージ確認 1 回 + 否認時ヒアリング 1 回）に制限する。

   - 質問文: `PR #<PR_NUMBER> (<PR_URL>) を作成しました。マージしてクリーンアップまで進めますか？`
   - 選択肢 1: `マージしてクリーンアップ (Recommended)`
   - 選択肢 2: `PR は残して改善項目を相談する`

   `Other`（自由入力）は `AskUserQuestion` が自動で付与する。`Other` の回答が承認と明確に解釈できる場合は選択肢 1 扱い。それ以外は選択肢 2 扱い。判定に迷ったら選択肢 2（否認側）に倒す。

   **承認時**: 次のステップ **c** に進む。

   **否認時**: `git-merge` を呼ばない。`AskUserQuestion` を 2 回目として 1 回だけ呼び、改善項目をヒアリングする。

   - 質問文: `改善したい内容を教えてください。`
   - 選択肢: なし（自由入力）

   ユーザーの回答を受け取ったら、`Followup: <回答>` として最終出力に反映する。これ以上 `AskUserQuestion` を呼ばない。

   **c. `git-merge` を呼ぶ（承認時のみ）**

   次のパラメータを渡す。

   - `PR_NUMBER` = 上で取得した値
   - `BRANCH` = `$BRANCH`
   - `WORKTREE_PATH` = `$WORKTREE_DIR`
   - `RUN_DIR` = `$RUN_DIR`
   - `REPO_ROOT` = `$(pwd)`（起動側リポジトリのルート）

5. **PASS でない / `MAX_ITER` 到達**: 最終化をスキップし、最新の評価レポートのパスと未解決の指摘をユーザーに表示して停止。push も PR 作成もマージ確認もクリーンアップも行わない

6. **ログ**: ループ脱出時または `MAX_ITER` 到達時に `.trinity/trinity.log` に終了行を追記する。

   ```shell
   # PASS で抜けたとき
   printf '=== %s run ended: PASS at iter %d ===\n' "${TS}-${SLUG}" "$n" >> .trinity/trinity.log

   # MAX_ITER で抜けたとき
   printf '=== %s run ended: %s at iter %d/%d ===\n' "${TS}-${SLUG}" "${VERDICT}" "$n" "$MAX_ITER" >> .trinity/trinity.log
   ```

7. **最終出力**: 次のフォーマットでちょうど印字し、2〜3 文の要約を添える。最終化を実施した（PASS で抜けた）場合だけ `PR:` `Merge:` `Cleanup:` の 3 行を加える。

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

   NEEDS_REVISION / FAIL のまま `MAX_ITER` に到達した場合は `PR:` `Merge:` `Cleanup:` 行を出さない。

`/trinity:run` の起動自体がパイプライン全体への明示的な許可（push と PR 作成を含む）だが、マージとクリーンアップだけは PR 作成後の `AskUserQuestion` で改めてユーザーの承認を取る。途中で他の確認プロンプトは挟まない。

---
description: "Planner → Generator → Evaluator のハーネスパイプラインを実行する。最終 PASS 後は push と PR 作成を行い、ユーザー承認のもとでマージとお片付けまでを完結させる。使用例 `/trinity:run <要件>` または `/trinity:run --max-iter=5 <要件>`。"
argument-hint: "[--max-iter=N] <1〜4文の要件>"
---

# /trinity:run — 3エージェント・ハーネスパイプライン

ハーネスを取り回すスラッシュコマンドである。Planner が要件を計画に展開し、Generator が隔離された worktree で実装してコミットし、Evaluator が独立に判定する。判定が PASS になるか、`max_iter` に到達するまで繰り返す。最終 PASS 後、worktree のブランチを push して PR を作成し、ユーザー承認のもとでマージとお片付けまでを行う。

## 使うスキル

このコマンドの実行手順は次の 6 スキルに分割されている。各フェーズで該当スキルを参照し、その手順に従う。スキル本文を要約せず、書かれている規範をそのまま守ること。

- `trinity-orchestration-discipline` — 全フェーズで参照する不変規範（直列実行、コードに触らない、要約しない、worktree は承認時のみ片付ける）
- `trinity-rundir-worktree` — 起動直後、要件 → slug → `RUN_DIR` / `WORKTREE_DIR` / `BRANCH` の作成
- `trinity-iter-loop` — 3 エージェントの直列ループと PASS / NEEDS_REVISION / FAIL 分岐、最終出力フォーマット
- `trinity-branch-push` — PASS 後の origin への push、再試行規約
- `trinity-pr-from-artifacts` — `plan.md` と最終 `eval-<n>.md` から PR を作り、`PR_NUMBER` / `PR_URL` を取得
- `trinity-merge-and-cleanup` — `AskUserQuestion` でマージ可否を確認し、承認時のみ squash マージと worktree/branch のお片付けを行う

## 引数

生の引数は `$ARGUMENTS` で受け取る。次の手順で解釈する。

- 先頭が `--max-iter=N`（N は正の整数）であれば `MAX_ITER = N` とし、そのトークンを取り除く
- 先頭が一致しない場合は `MAX_ITER = 15`（既定値）
- 残りを「要件」として扱う。要件が空ならユーザーに 1〜4 文の要件を求めて停止する

詳細は `trinity-iter-loop` の「引数の解釈」節に従う。

## プリフライト（hook 担当）

`UserPromptSubmit` hook が `/trinity:run` を検出したとき次を強制する。あなたはこれを再実装しない。

- カレントが git リポジトリであること
- ワーキングツリーが clean であること（汚れていれば prompt がブロックされる）
- 現在のブランチを stderr に表示する

このため、本コマンドが起動した時点で「現在のブランチが clean なベースライン」であることが保証されている。

## 実行手順

1. **準備**: `trinity-rundir-worktree` に従い、`BASE_BRANCH` を確定し、`RUN_DIR` `WORKTREE_DIR` `BRANCH` を作る。`.trinity/trinity.log` に開始行を書く

2. **ループ**: `trinity-iter-loop` に従い、`n = 1 .. MAX_ITER` で Planner → Generator → Evaluator を直列に呼ぶ。`trinity-orchestration-discipline` に従って段間でコードに触らない、要約しない

3. **PASS のとき**: 次を順に実行する
   - `trinity-branch-push` に従って origin に push
   - `trinity-pr-from-artifacts` に従って PR を作り、`PR_NUMBER` / `PR_URL` を取得
   - `trinity-merge-and-cleanup` に従って `AskUserQuestion` で確認し、承認時のみ squash マージと worktree/branch のお片付けを行う

4. **PASS でない / `MAX_ITER` 到達**: 最終化をスキップし、最新の評価レポートのパスと未解決の指摘をユーザーに表示して停止。push も PR 作成もマージ確認もお片付けも行わない

5. **最終出力**: `trinity-iter-loop` の「ユーザーへの最終出力」フォーマットでちょうど印字し、2〜3 文の要約を添える。否認時または `Cleanup:` が `partial` のときは、`trinity-merge-and-cleanup` の規範に従って未実行の手動コマンドを提示する

`trinity-iter-loop` がループ終了時に `.trinity/trinity.log` の終了行を追記する。`/trinity:run` の起動自体がパイプライン全体への明示的な許可（push と PR 作成を含む）だが、マージとお片付けだけは PR 作成後の `AskUserQuestion` で改めてユーザーの承認を取る。途中で他の確認プロンプトは挟まない。

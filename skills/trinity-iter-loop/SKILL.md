---
name: trinity-iter-loop
description: Trinity ハーネスの Planner → Generator → Evaluator イテレーションループを制御する。オーケストレーターが run ディレクトリと worktree を準備した後に参照する。`MAX_ITER` の解釈、各段の起動順、Planner/Generator が停止したときの処理、PASS / NEEDS_REVISION / FAIL に応じたループ脱出と継続、`MAX_ITER` 到達時の最終化スキップ、`.trinity/trinity.log` の終了行、ユーザーへの最終出力フォーマット（`PR` / `Merge` / `Cleanup` 行を含む）までを規定する。最終化（push、PR 作成、マージ確認、お片付け）は本スキルの責務外で、PASS のときだけ後続スキルに委ねる。
---

# trinity-iter-loop

Trinity のループは「同じ計画を複数回練り直しながら、コードと評価を往復させる」構造になっている。早期に終わらせず、かといって永遠に回さないように、本スキルがループ制御の規範を持つ。

## 引数の解釈

オーケストレーターは `$ARGUMENTS` を次の順で解釈する。

1. 先頭が `--max-iter=N`（N は正の整数）であれば `MAX_ITER = N` とし、そのトークンを取り除く
2. 先頭が一致しない場合は `MAX_ITER = 15`（既定値）
3. 残りを「要件」として扱う。空ならユーザーに 1〜4 文の要件を求めて停止する。先には進めない

`MAX_ITER` は1未満を受け付けない。受け取った値が 0 以下なら停止して報告する。

## 各段の起動

ループ `n = 1 .. MAX_ITER` で次を順に呼ぶ。並列にしない。各段は前段の出力ファイルに依存する。

### Planner

`trinity:planner` サブエージェントに次を渡す。

- 要件（原文ママ）
- `Iteration: <n>`
- `RUN_DIR: <絶対パス>`
- `WORKTREE_DIR: <絶対パス>`
- `n > 1` の場合、直前の評価が `${RUN_DIR}/eval-<n-1>.md` にある旨

返却されたパス（必ず `${RUN_DIR}/plan.md`）を保持する。Planner が `AskUserQuestion` でユーザーに確認を投げた場合は、その質問をそのまま見せて停止する。先に進めない。

### Generator

`trinity:generator` サブエージェントに次を渡す。

- `RUN_DIR: <絶対パス>`
- `WORKTREE_DIR: <絶対パス>`
- `BRANCH: <ブランチ名>`
- `Iteration: <n>`

返却された検証レポートとコミット SHA を保持する。Generator が検証失敗で自力修正もできずコミットを作れなかった場合は、ループを停止して失敗内容をユーザーに報告する。**存在しないコミットを Evaluator に渡してはいけない。**

### Evaluator

`trinity:evaluator` サブエージェントに次を渡す。

- `RUN_DIR: <絶対パス>`
- `WORKTREE_DIR: <絶対パス>`
- `Iteration: <n>`
- コミット SHA
- Generator の検証レポート

返却された評価レポートのパス（必ず `${RUN_DIR}/eval-<n>.md`）と判定（`PASS` / `NEEDS_REVISION` / `FAIL`）を保持する。

## 判定に応じた分岐

| 判定 | 残りイテレーション | 動作 |
| --- | --- | --- |
| `PASS` | — | ループ脱出。PASS 時の最終化（push、PR 作成、マージ確認、お片付け）は本スキル外。`trinity-branch-push` → `trinity-pr-from-artifacts` → `trinity-merge-and-cleanup` の順に委ねる |
| `NEEDS_REVISION` | `n < MAX_ITER` | 続行。Planner は次周回で `plan.md` を**新規作成せず上書き**する |
| `FAIL` | `n < MAX_ITER` | 続行。Planner はより踏み込んだ再計画を行う |
| `NEEDS_REVISION` または `FAIL` | `n == MAX_ITER` | 最終化をスキップ。最新の評価レポートのパスと未解決の指摘をユーザーに表示して停止 |

## ログ

ループ脱出時または `MAX_ITER` 到達時に必ず `.trinity/trinity.log` に終了行を追記する。

```shell
# PASS で抜けたとき
printf '=== %s run ended: PASS at iter %d ===\n' "${TS}-${SLUG}" "$n" >> .trinity/trinity.log

# MAX_ITER で抜けたとき（VERDICT は最後の判定）
printf '=== %s run ended: %s at iter %d/%d ===\n' "${TS}-${SLUG}" "${VERDICT}" "$n" "$MAX_ITER" >> .trinity/trinity.log
```

開始行は `trinity-rundir-worktree` が書く。終了行はここで書く。

## ユーザーへの最終出力

ループ終了時にちょうど次のフォーマットで印字する。最終化を実施した（PASS で抜けた）場合だけ `PR:` `Merge:` `Cleanup:` の 3 行を加える。

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

`PR_NUMBER` `PR_URL` は `trinity-pr-from-artifacts` から、`Merge:` と `Cleanup:` の値は `trinity-merge-and-cleanup` から受け取る。NEEDS_REVISION / FAIL のまま `MAX_ITER` に到達した場合は `PR:` `Merge:` `Cleanup:` 行を**出さない**。push も PR 作成もマージ確認もお片付けも行っていないからである。

その後に 2〜3 文の平易な要約を添える。否認時または `Cleanup:` が `partial` のときは、ユーザーが手動で実行すべきコマンドを `trinity-merge-and-cleanup` の規範に従って表示する。それ以上は書かない。

## やってはいけないこと

- 段を並列で呼ばない（前段の成果物に依存している）
- 段と段のあいだでオーケストレーターがコードを読み書きしない（`trinity-orchestration-discipline` 参照）
- Evaluator が `FAIL` を出したのを「だいたい OK」と解釈してループを抜けない
- `MAX_ITER` を黙って延長しない（既定 15 で足りないなら、ユーザーに `--max-iter` を指定し直してもらう）
- Planner にイテレーションごと別のファイル名で計画を書かせない（`plan.md` は固定で上書き）

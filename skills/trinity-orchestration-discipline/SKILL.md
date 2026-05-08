---
name: trinity-orchestration-discipline
description: Trinity ハーネスのオーケストレーター（`/trinity:run` のメイン実行者）が守るべき不変規範を提供する。サブエージェントを呼ぶたびに参照する。サブエージェントの直列実行、段間でのコード読み書き禁止、エージェント出力の要約禁止、worktree 後始末の禁止、Generator/Evaluator 間で共有すべき値の限定（`RUN_DIR` `WORKTREE_DIR` `BRANCH` とコミット SHA だけ）を規定する。Evaluator の独立性を構造的に担保するためのハーネス本質ルール。
---

# trinity-orchestration-discipline

Trinity の本質は「3 エージェントが**ファイルを介してだけ**通信する」ことにある。オーケストレーターが横着すると、この性質が瞬時に崩れて単一エージェント・ハーネスに退化する。本スキルはその退化を防ぐ規範をまとめる。

## 直列で呼ぶ

サブエージェントは並列ではなく直列に呼び出す。各段は前段の成果ファイル（`plan.md` / コミット / `eval-<n>.md`）に依存している。

並列化したくなる場面（例: Generator が長いから Evaluator を準備しておきたい）はあるが、Evaluator はコミット SHA を入力に取るので、Generator が終わってからしか起動できない。手を抜くと存在しない SHA を渡してしまう。

## 段と段のあいだでコードに触らない

オーケストレーターが `Read` `Edit` `Bash` で `${WORKTREE_DIR}` 内のコードを読んだり編集したりしてはいけない。例外なく禁止する。

これを破ると：

- Evaluator が「自分が読んだ事実」と「オーケストレーターが要約した事実」のどちらを信じるべきか分からなくなる
- 段の責務が曖昧になり、再現性が崩れる
- 失敗時の責任分界が不能になる

オーケストレーターが触ってよいのは次だけである。

- `${RUN_DIR}` 配下のファイル名一覧の確認（読まない、開かない）
- `.trinity/trinity.log` への開始行・終了行の追記
- `git -C "$WORKTREE_DIR" rev-parse` `git -C "$WORKTREE_DIR" remote get-url origin` などの非破壊・非読取の git メタ問い合わせ
- `git -C "$WORKTREE_DIR" push`（最終化のみ）

`plan.md` や `eval-<n>.md` の中身も、PR 本文を組み立てるとき以外は開かない。`trinity-pr-from-artifacts` のフェーズに来てから初めて開く。

## エージェント出力を要約して次段に渡さない

Generator の検証レポートを「テスト通った」と圧縮して Evaluator に渡してはいけない。Generator が書いたレポート本文をそのまま渡す。Evaluator はオーケストレーターのフィルタ越しではなく、Generator の生の主張を受け取る権利がある（その上で自分で再検証する）。

各段への入力は次のとおり最小化する。

- Planner: 要件文、`Iteration`、`RUN_DIR`、`WORKTREE_DIR`、必要なら `eval-<n-1>.md` の存在告知
- Generator: `RUN_DIR`、`WORKTREE_DIR`、`BRANCH`、`Iteration`
- Evaluator: `RUN_DIR`、`WORKTREE_DIR`、`Iteration`、コミット SHA、Generator の検証レポート

それ以外を渡さない。各エージェントは `RUN_DIR` から自分で必要なファイルを読む。**「ファイルから動く」がハーネスの核**である。

## worktree の後始末は承認時のみ行う

worktree とブランチを消すかどうかは PR 作成後の `AskUserQuestion`（`trinity-merge-and-cleanup` が担当）の回答に従う。承認されたら squash マージしてから worktree とローカル/リモートブランチを消す。否認、または NEEDS_REVISION / FAIL のまま `MAX_ITER` に到達した場合は触らない。

オーケストレーターが先回りして消さない。`.trinity/<run>/` は gitignore されており、worktree は監査ログ兼再現環境として価値がある。`plan.md` `eval-*.md` `trinity.log` は承認時でも残す（`trinity-merge-and-cleanup` 参照）。

否認 / partial / `MAX_ITER` 到達のときは、未実行の手動コマンドを最終出力の後に提示する。ユーザーが行き詰まらないようにする。

## 最終出力以外を喋らない

ループ中、各段の途中報告をユーザーに垂れ流さない。サブエージェントの内部独白を中継しない。最終的に `trinity-iter-loop` で規定された出力フォーマット 1 ブロック + 2〜3 文の要約だけを返す。

例外は次の 4 つだけである。

- Planner が `AskUserQuestion` で確認を投げた → そのまま見せて停止
- Generator がコミットを作れずに停止 → 失敗内容を見せて停止
- push に恒久失敗が起きた → 原文を見せて停止（`trinity-branch-push` 参照）
- `trinity-merge-and-cleanup` のマージ確認 `AskUserQuestion` → ユーザー回答を待つ（最終出力より前に 1 回だけ）

## 受け渡しに使ってよい値

オーケストレーターが各段に渡してよいのは次だけである。これら以外をエージェントに渡さない（特に「要約された前段の出力」を渡さない）。

| 値 | 中身 | 誰が決めるか |
| --- | --- | --- |
| `BASE_BRANCH` | 起動時のブランチ名 | `trinity-rundir-worktree` |
| `RUN_DIR` | `.trinity/<TS>-<slug>` の絶対パス | `trinity-rundir-worktree` |
| `WORKTREE_DIR` | `${RUN_DIR}/worktree` の絶対パス | `trinity-rundir-worktree` |
| `BRANCH` | `trinity/<TS>-<slug>` | `trinity-rundir-worktree` |
| `Iteration` (n) | 1 オリジン整数 | `trinity-iter-loop` |
| コミット SHA | Generator が作った 1 コミットの SHA | Generator |
| Generator 検証レポート | Generator の最終出力テキストそのまま | Generator |

## やってはいけないこと

- 段を並列化する
- `${WORKTREE_DIR}` 内のコードを読む / 開く / 編集する
- エージェント出力を要約・整形してから次段に渡す
- マージ確認の `AskUserQuestion` を経ずに worktree やブランチを消す
- マージ確認の `AskUserQuestion` を複数回呼ぶ（必ず 1 回。`trinity-merge-and-cleanup` 参照）
- 段の途中で進捗をユーザーに垂れ流す（最終出力にまとめる）
- `RUN_DIR` `WORKTREE_DIR` `BRANCH` を相対パスで渡す（必ず絶対パス）

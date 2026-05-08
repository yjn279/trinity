---
name: trinity-rundir-worktree
description: Trinity ハーネスの run ディレクトリと隔離 git worktree を作る手順を提供する。`/trinity:run` のオーケストレーターが、要件文字列を受け取った直後、各サブエージェントを起動する前に必ずこのスキルを参照する。要件 → kebab-case slug、UTC タイムスタンプ、`RUN_DIR` `WORKTREE_DIR` `BRANCH` の決定、`git worktree add`、`.trinity/trinity.log` の開始行追記、命名衝突時の suffix 付与までを規定する。
---

# trinity-rundir-worktree

Trinity の各 run は、独立したディレクトリと隔離 worktree を持つ。これを作るのはオーケストレーターの責務であり、サブエージェントが触る前にすべて確定させる。

## 前提

`UserPromptSubmit` hook が `/trinity:run` を検出した時点で次が保証されている。再検査しない。

- カレントが git リポジトリである
- ワーキングツリーが clean である
- 現在のブランチ名が stderr に表示済み

このブランチを `BASE_BRANCH` として捕捉する。

```shell
BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

## スラッグの作り方

要件（1〜4文）から英字 kebab-case の slug を作る。

- 2〜5語にする（多すぎても少なすぎても識別性が落ちる）
- 動詞 + 目的語の形を優先する（例 「ユーザー設定ページにテーマトグルを追加する」→ `add-theme-toggle`）
- ASCII 英小文字と数字とハイフンのみ。日本語は含めない（Windows と URL の互換性）
- 既存の `.trinity/<TS>-<slug>` と衝突した場合のみ末尾に `-2` `-3` を付ける

## RUN_DIR と worktree の生成

```shell
TS=$(date -u +%Y%m%dT%H%M%SZ)
SLUG=<上のルールで作る>
RUN_DIR="$(pwd)/.trinity/${TS}-${SLUG}"
WORKTREE_DIR="${RUN_DIR}/worktree"
BRANCH="trinity/${TS}-${SLUG}"
mkdir -p "$RUN_DIR"
git worktree add -b "$BRANCH" "$WORKTREE_DIR" "$BASE_BRANCH"
printf '=== %s run started on %s (base=%s) ===\n' "${TS}-${SLUG}" "${BRANCH}" "${BASE_BRANCH}" >> .trinity/trinity.log
```

`pwd` は絶対パスで取る。`RUN_DIR` `WORKTREE_DIR` は以降の全段に絶対パスで渡す。相対パスを混ぜると Bash 呼び出し間で cwd が引き継がれない問題に直撃する。

## 受け渡し

このスキルが終わった時点で、以降のオーケストレーション全体に次の4変数を持ち回す。

- `BASE_BRANCH` — push 時の PR base、worktree の派生元
- `RUN_DIR` — `plan.md` `eval-<n>.md` の置き場（オーケストレーター・全サブエージェントが読み書き）
- `WORKTREE_DIR` — Generator が読み書きする実装対象。Evaluator は読み取り専用
- `BRANCH` — push 対象、PR の head

## やってはいけないこと

- worktree を `BASE_BRANCH` 上に直接作らない（隔離が崩れる）
- `cd` してから `git worktree add` を打たない（必ず `git -C` か絶対パスで）
- 同一秒で衝突したのに既存 worktree を上書きしない（必ず suffix を付ける）
- `RUN_DIR` 配下を `.gitignore` していない場合でも、ここで `.gitignore` 編集を試みない（リポジトリ側の設定責務）

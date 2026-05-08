---
name: trinity-pr-from-artifacts
description: Trinity の PASS 後に、`plan.md` と最終 `eval-<n>.md` から PR タイトルと本文を組み立て、`mcp__github__create_pull_request` で PR を作る。`trinity-branch-push` で push が成功した直後に参照する。`.trinity/` は gitignore されておりレビュアーから見えないため、計画と判定の核心を PR 本文に埋め込むのが本スキルの目的である。リポジトリ owner/repo の取り出し、タイトル長制限、欠損セクションのフォールバックも規定する。
---

# trinity-pr-from-artifacts

`/trinity:run` の起動自体が PR 作成への明示的な許可なので、ユーザー確認は取らずに進める。レビュアーは `.trinity/` を見られないため、本文に必要な情報をすべて埋め込む。

## 前提

push が成功している（`trinity-branch-push` 完了）。次が確定している。

- `BASE_BRANCH` — PR の base
- `BRANCH` — PR の head（`trinity/<TS>-<slug>`）
- `RUN_DIR` — `${RUN_DIR}/plan.md` と `${RUN_DIR}/eval-<n>.md` を読む
- 最終イテレーション番号 `n`
- 最終コミット SHA

## ツール

`mcp__github__create_pull_request` を使う。スキーマが未ロードなら呼ぶ前に読み込む。

```
ToolSearch query="select:mcp__github__create_pull_request"
```

owner と repo は worktree の origin から取り出す。

```shell
git -C "$WORKTREE_DIR" remote get-url origin
```

`https://github.com/<owner>/<repo>.git` または `git@github.com:<owner>/<repo>.git` のどちらにも対応する。末尾の `.git` は剥がす。

## タイトル

`${RUN_DIR}/plan.md` の先頭 H1（`# <タイトル>`）の本文をそのまま使う。70 文字を超えるなら**冒頭から**70 文字で切り詰める（末尾省略しない、切れ目に `…` も付けない。GitHub の PR タイトルは長くても表示が崩れないが、72 文字付近を一線にして固定する）。

H1 が見つからない場合は、要件冒頭 70 文字をフォールバックとして使う。

## 本文テンプレート

`plan.md` と `eval-<n>.md` の構造は `trinity:planner` `trinity:evaluator` のテンプレで規定されている。本文は次のとおり組み立てる。

```markdown
## 概要

<plan.md の `## 背景` セクション本文をそのまま貼る>

## ゴール

<plan.md の `## ゴール` セクションを箇条書きでそのまま貼る>

## 受け入れ基準

<plan.md の `## 受け入れ基準（Evaluator用チェックリスト）` セクションを箇条書きでそのまま貼る>

## Trinity 実行サマリ

- Run: <RUN_DIR を repo ルートからの相対パスで>
- Iterations: <n>/<MAX_ITER>
- Final verdict: PASS
- Final commit: <短縮SHA>

## 判定根拠（最終 Evaluator レポートからの抜粋）

<eval-<n>.md の `## 軸別スコア` セクションをそのまま貼る>
```

`base = $BASE_BRANCH`、`head = $BRANCH` で PR を作る。

## 欠損時のフォールバック

`plan.md` に該当セクションが無い場合は、その節を本文から省く（空 H2 を残さない）。Evaluator のレポートに `## 軸別スコア` が無ければ `## 受け入れ基準` 節を代用する。Planner / Evaluator のテンプレ自体が変わった場合は、そちらの修正と本スキルの更新を同期させる。

`plan.md` の `path:line` 引用は `WORKTREE_DIR` 起点の相対パスで書かれている。これはリポジトリルート起点の相対パスでもあるので、PR 本文に貼ったときレビュアーが GitHub 上でクリック追跡できる。書き換えない。

## ユーザーへの戻り値

PR 作成レスポンスから次の 2 値を取り出して保持する。両方とも後続スキルが必要とする。

- `PR_NUMBER` — `trinity-merge-and-cleanup` がマージ確認の質問文と `mcp__github__merge_pull_request` 呼び出しに使う
- `PR_URL` — `/trinity:run` の最終出力 `PR:` 行と、`trinity-merge-and-cleanup` がマージ失敗時にユーザーへ提示する

オーケストレーターは PR 作成が成功したら、続けて `trinity-merge-and-cleanup` を呼ぶ。マージ確認まで含めて 1 セットの最終化である。

## やってはいけないこと

- `.trinity/` 内のファイルを PR 本文にリンクとして貼らない（gitignored で 404 になる）。本文に直接転記する
- PR タイトルに `[trinity]` のような自動付与ラベルを足さない（Plan の H1 をそのまま使う）
- ユーザー確認のプロンプトを挟まない（`/trinity:run` 起動時点で許可済み）
- PR の base を `BRANCH` 自身や `main` に固定しない（必ず `$BASE_BRANCH` を使う。ユーザーの起動時ブランチが想定外の base でも、それを尊重する）

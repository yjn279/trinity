---
description: "Harness for long-running tasks."
argument-hint: "<issue number(s) or a short requirement>"
---

# Trinity

Trinity は、AIエージェントが Production-Ready の品質水準を満たしながら長時間の業務を遂行するためのハーネスです。

## Overview

Trinity は Planner・Generator・Evaluator の3サブエージェントと、それを束ねる Orchestrator で構成されます。Plannerの計画に沿って Generator が実装し、Evaluator が妥協なく評価する——この敵対的な往復が、機械には下せない品質（要件適合・デザインの美・コードの美・要件妥当性）を生みます。

機械が下せる8割（実行検証・差分レビュー・整理）は、Evaluator の道具として組み込みコマンド `/verify`・`/run`・`/code-review --fix`・`/simplify` に委ねます。Evaluator はその上で、削れない2割の判断にだけ希少な判断力を注ぎます。

- Planner：要件を受け入れ基準付きの計画に展開する（Issue ごとに存在）。
- Generator：計画のタスクを worktree 内で実装し、1コミットする。
- Evaluator：コミットを独立・読み取り専用で評価し、3値判定を下す。

あなた（Orchestrator）はメイン会話のフォアグラウンドにいます。**コードには一切触れません。** あなたの仕事は、自由形式の要件を解釈してユーザーと対話し、要件から依存グラフ・並列可否を**判断**し、起動してよい Issue をシェルへ渡して背景で走らせ、監視することです。**判断はあなた、配管はシェル。**

| 機構 | 実体 | 役割 |
| :-- | :-- | :-- |
| `bin/trinity loop` | シェル（サブコマンド） | 1 Issue の `Plan → Generator → 道具 → Evaluator` 収束ループ。背景で走る |
| `bin/trinity supervise` | シェル（サブコマンド） | `backlog.tsv` を読み、起動可能な Issue を背景起動し、手当てが要るイベントまでブロックして待つ |
| `lib/actors.sh` | シェル | `claude -p` トランスポート。アクター呼び出し層 |

ハーネスのスクリプトは `${CLAUDE_PLUGIN_ROOT}/bin/trinity` にあります。

## Instructions

### 1. 要件の受領と精緻化

要件を受け取る（Issue 番号でも自由形式の文でもよい）。設計が分岐するほどの曖昧さがあれば、起動の前にここで `AskUserQuestion` を使って詰める。あなたはフォアグラウンドにいるので `AskUserQuestion` をネイティブに呼べる。要件レベルの曖昧さをここで解消しておくほど、背景の Planner が確認に戻る必要が減る。

### 2. 分解と環境構築

要件を解釈し、どのような作業単位（Issue）に分けるかを判断する。単発 Issue のこともあれば、複数 Issue のことも、そもそも Issue として切らないこともある。Trinity 実施後に修正に入ることもある。各ケースに素直に対応する。

各 Issue について `git-flow` スキルに従ってブランチと worktree を切り出し、`RUN_DIR`（`.trinity/<session>/<slug>/`）を作って `requirement.md`（要件と確定事項）を書き込む。

依存関係・並列可否の判断はあなたが行う。**いま起動できる Issue だけ** を `SESSION_DIR`（`.trinity/<session>/`）の `backlog.tsv` に書く。タブ区切りで1行=1 Issue:

```text
slug<TAB>worktree<TAB>branch<TAB>title
```

後続 Issue（先行の完了を待つもの）は、先行が `passed` に達したときに worktree を用意して backlog に追記し、手順3を再実行する。

既に作業環境が構築済みの場合はそれを再利用する。

### 3. 起動（supervise）

`trinity supervise` を呼び、`backlog.tsv` を読んで起動可能な Issue を背景で立てる。コマンドは起動後、手当てが要るイベントまでブロックして待ち、`STATUS` 表と `EVENT:` 行を返す。

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/trinity" supervise "${SESSION_DIR}"
```

### 4. 監視（EVENT 対応）

返ってきた `EVENT:` 行に従って対応し、`done` か `timeout` まで手順3を繰り返す。

| EVENT | 対応 |
| :-- | :-- |
| `needs-input` | `ISSUE:` 行の各 slug について `<RUN_DIR>/ask/q`（Planner の `## 要確認の論点`）を読み、`AskUserQuestion` でユーザーに提示する。内容は解釈・判定せず運搬する。回答を `<RUN_DIR>/ask/a` に書く——パイプラインのブロックが解け、Planner が確定事項を反映して再計画する。複数あれば Issue ごとに直列で問う。`AskUserQuestion` を呼ぶのは常にあなた一人。 |
| `done` | 現在の backlog が全て終端（passed/failed/error）。未起動の後続 Issue があれば worktree を用意して backlog に追記し手順3を再実行する。なければ手順5へ。 |
| `timeout` | 監視が上限に達した。`STATUS` 表を共有し、ユーザーに継続可否を確認する。継続する場合は手順3を再実行する。作業環境と `.trinity/<session>/` が残っていれば、`loop` は段ごとのチェックポイント（`plan-<n>.md`・`gen-<n>-task-<i>.md`・`eval-<n>.md`）から完了済みの段・タスクをスキップして中断点から再開する。 |

`<RUN_DIR>/status` が `passed` の Issue は PR 作成へ進める。`failed`（ループ上限で未到達）・`error` の Issue は、`eval-*.md`・`pipeline.out` を読んで原因をユーザーに報告する。あなたはコードを直さない。

### 5. Pull Request の作成

`passed` の Issue ごとに `git-flow` スキルに従って独立した PR を作成する（マージはしない）。既存 PR があれば追加 Push し変更点をコメントする。タイトルは Conventional Commits 接頭辞付きの日本語命令形。本文は次の見出し構成にする。

```markdown
## 目的

## 実装内容

## 変更点サマリ
```

### 6. 修正判断のヒアリング

PR の URL を共有し、`AskUserQuestion` で修正要否を仰ぐ。必要なら該当 Issue の `requirement.md` を更新して手順3から回し直す。不要なら次へ。

### 7. 課題起票

ユーザーの要望、または改善すべき課題を見つけた場合、`AskUserQuestion`（`multiSelect=true`）で起票を提案し、選ばれた課題を登録する。対象リポジトリと Trinity 本体で宛先を分ける。

```bash
gh issue create --repo <owner/repo> --title "<title>" --body "<body>"
gh issue create --repo yjn279/trinity --title "<title>" --body "<body>"
```

### 8. クリーンアップ

ユーザーから明示的な許可を受けたら、`git-flow` スキルに従い各環境（ブランチ・worktree）をクリーンアップし、対応する Issue をクローズする。`.trinity/<session>/` の該当フォルダも削除する。

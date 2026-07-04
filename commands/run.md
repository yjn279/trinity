---
description: "Harness for long-running tasks."
argument-hint: "<issue number(s) or a short requirement>"
---

# Trinity

あなた（Orchestrator）はメイン会話のフォアグラウンドにいる。Planner・Generator・Evaluator の3アクターを束ね、Planner の計画に沿って Generator が実装し Evaluator が妥協なく評価する敵対的な往復を、Production-Ready まで回す。あなたが実装するのはユーザーの要件であり、その仕様は起動時の対話と各 Issue の `requirement.md` で定まる（この Trinity 自体の仕様書ではない）。

**あなたは一切コードに触れない。** 仕事は、自由形式の要件を解釈してユーザーと対話し、要件から依存・並列可否を**判断**して起動してよい Issue をシェルへ渡し、背景で走らせて監視すること。**判断はあなた、配管はシェル。** 内側ループ（`Plan → Generator → 道具 → Evaluator`）は `${CLAUDE_PLUGIN_ROOT}/bin/trinity` が背景で回す（`loop` が1 Issue の収束ループ、`supervise` が backlog 各行の起動と監視）。

## Instructions

### 1. Intake

要件を受け取る（Issue 番号でも自由形式の文でもよい）。設計が分岐するほどの曖昧さがあれば、起動の前にここで `AskUserQuestion` を使って詰める。あなたはフォアグラウンドにいるので `AskUserQuestion` をネイティブに呼べる。要件レベルの曖昧さをここで解消しておくほど、背景の Planner が確認に戻る必要が減る。

### 2. Setup

環境構築の前に、`git-flow` スキルと `code-review` コマンドが導入済みかを確認する。未導入のものがあれば、`/trinity:run` 起動を暗黙の許可とみなし、確認なしで自動セットアップを実施する（`~/.claude` への変更を含む）。

要件を解釈し、どのような作業単位（Issue）に分けるかを判断する。単発 Issue のこともあれば、複数 Issue のことも、そもそも Issue として切らないこともある。Trinity 実施後に修正に入ることもある。各ケースに素直に対応する。

各 Issue について `git-flow` スキルに従ってブランチと worktree を切り出し、`RUN_DIR`（`.trinity/<session>/<slug>/`）を作って `requirement.md`（要件と確定事項）を書き込む。

依存関係・並列可否の判断はあなたが行う。**いま起動できる Issue だけ** を `SESSION_DIR`（`.trinity/<session>/`）の `backlog.tsv` に書く。タブ区切りで1行=1 Issue:

```text
slug<TAB>worktree<TAB>branch<TAB>title
```

後続 Issue（先行の完了を待つもの）は、先行が `passed` に達したときに worktree を用意して backlog に追記し、手順3を再実行する。

既に作業環境が構築済みの場合はそれを再利用する。

### 3. Launch

`trinity supervise` を呼び、`backlog.tsv` を読んで起動可能な Issue を背景で立てる。コマンドは起動後、手当てが要るイベントまでブロックして待ち、`STATUS` 表と `EVENT:` 行を返す。

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/trinity" supervise "${SESSION_DIR}"
```

### 4. Monitor

`supervise` は `needs-input` か `done` を返す。それに従って対応し、`done` まで手順3を繰り返す。

| EVENT | 対応 |
| :-- | :-- |
| `needs-input` | `ISSUE:` 行の各 slug について `<RUN_DIR>/ask/q`（Planner の `## 要確認の論点`）を読み、`AskUserQuestion` でユーザーに提示する。内容は解釈・判定せず運搬する。回答を `<RUN_DIR>/ask/a` に書く——パイプラインのブロックが解け、Planner が確定事項を反映して再計画する。複数あれば Issue ごとに直列で問う。`AskUserQuestion` を呼ぶのは常にあなた一人。 |
| `done` | 現在の backlog が全て終端（passed/failed/error）。未起動の後続 Issue があれば worktree を用意して backlog に追記し手順3を再実行する。なければ手順5へ。 |

API 課金エラーやレートリミットで途中停止しても、作業環境と `.trinity/<session>/` が残っていれば手順3を再実行すればよい。`loop` は段ごとのチェックポイント（`plan-<n>.md`・`gen-<n>-task-<i>.md`・`gen-<n>-revise.md`・`eval-<n>.md`）から完了済みの段・タスクをスキップして中断点から再開する。

`<RUN_DIR>/status` が `passed` の Issue は PR 作成へ進める。`failed`（ループ上限で未到達）・`error` の Issue は、`eval-*.md`・`pipeline.out` を読んで原因をユーザーに報告する。あなたはコードを直さない。

### 5. Pull Request

`passed` の Issue ごとに `git-flow` スキルに従って独立した PR を作成する。既存 PR があれば追加 Push し変更点をコメントする。タイトルは Conventional Commits 接頭辞付きの日本語命令形。本文は次の見出し構成にする。

```markdown
## 目的

## 実装内容

## 変更点サマリ
```

### 6. Merge

作成した PR の URL をユーザーへ共有し、`AskUserQuestion`（`multiSelect=true`）で PR 群をマージ候補として提示する。

- **選択された PR**: `gh pr merge` でマージする。
- **非選択の PR**: Other 欄の記入で判断する。記入があれば修正要望として該当 Issue の `requirement.md` を更新し手順3から回し直す。記入が無ければ据え置く（マージしない）。

修正用の独立した選択肢は設けない。修正内容は Other 欄で受ける。

### 7. Wrap-up

マージの確定後、課題起票とクリーンアップを1回の `AskUserQuestion` コール（最大3問）でまとめて確認する。クリーンアップは誤承認を避けるため必ず独立した1問にする。

| 問い | 提示条件と動作 |
| :-- | :-- |
| 対象リポジトリへの課題起票 | 要望があった場合、または対象リポジトリで改善すべき課題を見つけた場合のみ提示。`multiSelect=true` で提示し、選択された課題を登録する。 |
| Trinity への課題起票 | 要望があった場合、または Trinity 自体で改善すべき課題を見つけた場合のみ提示。`multiSelect=true` で提示し、選択された課題を登録する。 |
| クリーンアップ許可 | 独立した1問として提示。許可を受けたら `git-flow` スキルに従い各環境（ブランチ・worktree）をクリーンアップし、`.trinity/<session>/` の該当フォルダを削除する。マージ済み PR に紐づく Issue は自動クローズ済みのため対象外とし、未マージのまま残る PR に対応する Issue のみ手動でクローズする。 |

```bash
gh issue create --repo <owner/repo> --title "<title>" --body "<body>"
gh issue create --repo yjn279/trinity --title "<title>" --body "<body>"
```

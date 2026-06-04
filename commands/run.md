---
description: "Harness for long-running tasks."
argument-hint: "<issue number(s) or a short requirement>"
---

# Trinity

TrinityはAIエージェントがProduction-Readyの品質水準を満たす、かつ長時間の業務を実行するために設計されたハーネスです。

## Overview

Trinityは、Planner・Generator・Evaluatorの3つのサブエージェントとそのオーケストレーターにより構成されます。Plannerの作業計画に基づき、Production-Readyな品質水準を満たすまでGenerator/EvaluatorがGANのように相互作用することで、品質の高い業務を遂行可能です。

- Planner：ユーザーの要望を作業計画に展開する。
- Generator：Plannerが作成した計画に沿って業務を実施する。
- Evaluator：Generatorが実施した業務が品質を満たすか判断する。

## Instructions

1. 対象の識別と環境構築

    要件を受け取る。要件は Issue 番号で渡されることも、自由記述で渡されることもある。Issue 番号が指定された場合は対象 Issue 群を識別し、変更同士が互いに影響するかを判断して環境を整備する。

    互いに影響しない変更は、変更ごとに固有の環境（ブランチ・worktree・`RUN_DIR`）を `git-flow` スキルに従って整備し、手順2以降のパイプラインを並列に起動する。各パイプラインは独立した3値判定ループを PASS まで回し、それぞれ独立した PR を生む。影響する変更は、依存する変更の実装が完了してから後続を直列で実装する。この場合も `git-flow` スキルに従って変更ごとに環境を整備し、各 Issue は独立した PR として残し、統合（マージ）はしない。

    既に作業環境が構築済みの場合はそれを再利用する。

2. イテレーションの実行：サブエージェントを直列かつ同期的に呼び、作業を実行する。実行途中の作業を開始する場合は、実行が完了している最新イテレーションの次から再開する。

    1. Planner
    2. Generator（複数チャンク）
    3. Evaluator
    4. code-review: Orchestrator（メイン会話）が子プロセスとして Claude をヘッドレス起動し、`/code-review` を `WORKTREE_DIR` 内のコミット（base との diff）に対して実行させる。理由は2つ。①スラッシュコマンドはサブエージェント（Planner・Generator・Evaluator）では動かず、メイン会話でしか実行できない。②`/code-review` は内部で複数エージェントを起動する重い機構であるため、子プロセス＋ファイル経由にして Orchestrator のコンテキストから隔離する。Orchestrator はレビュー結果ファイルだけを読む（生のレビュー過程はコンテキストに載せない）。

        代表的な起動コマンド:

        ```bash
        env -u CLAUDECODE claude -p \
          "/code-review $(git -C "$WORKTREE_DIR" rev-parse HEAD) $(git -C "$WORKTREE_DIR" merge-base HEAD 835fa6a)" \
          --permission-mode bypassPermissions \
          > "${RUN_DIR}/code-review-${n}.md"
        ```

    Trinityのオーケストレーターはコードに触れてはいけない。コードの変更は必ずGeneratorに移譲する。

    設計分岐の確認と Planner 再起動: Planner が `plan.md` 冒頭に `## 要確認の論点`（論点・選択肢・推奨の形）を書いた場合、Orchestrator はそのセクションを読み `AskUserQuestion` でユーザーへ提示する。Orchestrator は論点の中身を解釈・判定せず、そのまま運搬する。確認後、Orchestrator はユーザーの回答（確定事項）を添えて Planner を必ず再起動する（条件分岐なし）。再計画の要否は Planner が判断する。回答が Planner 自身の推奨どおりなら Planner は同じ plan を再出力すればよく、推奨と食い違えば plan を改める。責務分界: 設計分岐の検出は（コードを読んだ）Planner、論点と回答の運搬・無条件の再起動は Orchestrator、再計画の要否判断は Planner。

3. 次回イテレーションの実行判断：Evaluator の評価と code-review の結果により、以下の表に従って後続対応を判断、実行する。完了（ループ脱出して PR 作成へ進む）は Evaluator が PASS かつ code-review に must-fix の指摘が無い場合のみ。code-review に must-fix がある場合は Generator が既存計画の範囲内で修正し、Evaluator 評価と code-review を再度回す。なお、子プロセスの code-review は内部で6+エージェントを起動するため、評価1回あたりのコストが増える点に留意する。

    | 判定 | 動作 |
    | --- | --- |
    | Evaluator `PASS` かつ code-review must-fix なし | ループ脱出。次の手順へ進む。 |
    | Evaluator `PASS` かつ code-review must-fix あり | 続行。Generator は既存計画の範囲内で修正し、Evaluator 評価と code-review を再度回す。 |
    | Evaluator `NEEDS_REVISION` | 続行。Planner は次周回で `plan.md` を上書きする。 |
    | Evaluator `FAIL` | 続行。Generatorは修正作業を実施する。 |

4. Pull Requestの作成

    `git-flow` スキルに従い、Pull Requestを作成する。Issue ごとに独立した PR を作成する。影響する変更を直列に実装した場合も、各 Issue の PR は統合（マージ）せずそれぞれ独立した PR として残す。既存のPull Requestがある場合、そこに追加でPushして変更点をコメントとして記載する。

    ```
    ---
    title: 本文には記載しない。
    ---

    ## 目的

    ## 実装内容

    ## 変更点サマリ

    ```

5. 修正判断のヒアリング

    PRのURLをユーザーへ共有し、 `AskUserQuestion` で修正判断を仰ぐ。修正が必要な場合は手順2以降の手続きに従って修正を実行し、修正が必要が不要な場合は手順6に進む。

6. 対象リポジトリの課題起票

    ユーザーからの要望があった場合、もしくはTrinity自体が改善すべき課題を見つけた場合は、 `AskUserQuestion` で**対象リポジトリ**の課題起票を提案する。課題は `multiSelect=true` 形式ですべて提示し、そのうち実際に起票する課題をユーザーに選択してもらう。ユーザーが選択した課題は以下の `gh` コマンドでGitHub Issueとして登録する。

    ```bash
    gh issue create --repo <owner/repo> --title "<title>" --body "<body>"
    ```

7. Trinityの課題起票

    ユーザーからの要望があった場合、もしくはTrinity自体が改善すべき課題を見つけた場合は、 `AskUserQuestion` で**Trinity**の課題起票を提案する。課題は `multiSelect=true` 形式ですべて提示し、そのうち実際に起票する課題をユーザーに選択してもらう。ユーザーが選択した課題は以下の `gh` コマンドでGitHub Issueとして登録する。

    ```bash
    gh issue create --repo yjn279/trinity --title "<title>" --body "<body>"
    ```

8. クリーンアップ

    ユーザーから明示的な許可を受けたら、`git-flow` スキルに従い各環境（ブランチ・worktree）をクリーンアップし、対応する Issue をクローズする。独立パイプラインが複数ある場合は各環境と各 Issue をそれぞれ処理する。また、`.trinity/` にある該当フォルダは削除する。

## Subagents

### Planner

Plannerは作業計画の作成時に、コミット単位となる最適粒度で実装タスクをチャンク `M` に分割する。チャンクはそれぞれがエラーなく独立して動作し、検証可能な最小単位である。

### Generator

Generatorはチャンクごとに起動し、定められたチャンク内の実装タスクを実行する。チャンクの実装が完了したら、次のチャンクを実装するためのGeneratorを新たに起動する。

### Evaluator

すべてのチャンクのタスクが完了後に、次のコマンドでイテレーション内の最終コミットSHAを取得し、SHAをEvaluatorに渡す。Evaluatorは妥協なく実装を評価してイテレーションを繰り返し、Production-Readyな品質水準が確保できたタイミングで実装の完了を承認する。

```bash
LAST_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
```

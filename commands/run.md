---
description: "Harness for long-running tasks."
argument-hint: "<1〜4文の要件>"
---

# Trinity

TrinityはAIエージェントがProdcuion-Readyの品質水準を満たす、かつ長時間の業務を実行するために設計されたハーネスです。

## Overview

Trinityは、Planner・Generator・Evaluatorの3つのサブエージェントとそのオーケストレーターにより構成されます。Plannerの作業計画に基づき、Prodcuion-Readyな品質水準を満たすまでGenerator/EvaluatorがGANのように相互作用することで、品質の高い業務を遂行可能です。

- Planner：ユーザーの要望を作業計画に展開する。
- Generator：Plannerが作成した計画に沿って業務を実施する。
- Evaluator：Generatorが実施した業務が品質を満たすか判断する。

## Instructions

1. 作業環境の構築： `git-flow` スキルに基づき、作業環境を構築する。すでに作業環境が構築済みの場合はそれを利用する。
2. イテレーションの実行：サブエージェントを直列かつ同期的に呼び、作業を実行する。実行途中の作業を開始する場合は、実行が完了している最新イテレーションの次から再開する。
    1. Planner
    2. Generator（複数チャンク）
    3. Evaluator

    Trinityのオーケストレーターはコードに触れてはいけない。コードの変更は必ずGeneratorに移譲する。

3. 次回イテレーションの実行判断：Evaluatorの評価により、以下の表に従って後続対応を判断、実行する。

    | 判定 | 動作 |
    | --- | --- |
    | `PASS` | ループ脱出。次の手順へ進む。 |
    | `NEEDS_REVISION` | 続行。Planner は次周回で `plan.md` を上書きする。 |
    | `FAIL` | 続行。Generatorは修正作業を実施する。 |

4. Pull Requestの作成

    `git-flow` スキルに従い、Pull Requestを作成する。既存のPull Requestがある場合、そこに追加でPushして変更点をコメントとして記載する。

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

    ユーザーから明示的な許可を受けたら、 `git-flow` に従い環境をクリーンアップする。また、 `.trinity/` にある該当フォルダは削除する。

## Subagents

### Planner

Plannerは作業計画の作成時に、コミット単位となる最適粒度で実装タスクをチャンク `M` に分割する。チャンクはそれぞれがエラーなく独立して動作し、検証可能な最小単位である。

### Generator

Generatorはチャンクごとに起動し、定められたチャンク内の実装タスクを実行する。チャンクの実装が完了したら、次のチャンクを実装するためのGeneratorを新たに起動する。

### Evaluator

すべてのチャンクのタスクが完了後に、次のコマンドでイテレーション内の最終コミットSHAを取得し、SHAをEvaluatorに渡す。Evaluatorは妥協なく実装を評価してイテレーションを繰り返し、Prodcuion-Readyな品質水準が確保できたタイミングで実装の完了を承認する。

```bash
LAST_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
```

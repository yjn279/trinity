---
description: "Harness for long-running tasks."
argument-hint: "<対象 Issue 番号または 1〜4 文の要件。複数 Issue を同時に指定してもよい>"
---

# Trinity

TrinityはAIエージェントがProduction-Readyの品質水準を満たす、かつ長時間の業務を実行するために設計されたハーネスです。

## Overview

Trinityは、Planner・Generator・Evaluatorの3つのサブエージェントとそのオーケストレーターにより構成されます。Plannerの作業計画に基づき、Production-Readyな品質水準を満たすまでGenerator/EvaluatorがGANのように相互作用することで、品質の高い業務を遂行可能です。

- Planner：ユーザーの要望を作業計画に展開する。
- Generator：Plannerが作成した計画に沿って業務を実施する。
- Evaluator：Generatorが実施した業務が品質を満たすか判断する。

## Instructions

1. 対象 Issue 群の識別と環境構築

    要件から対象 Issue 群を識別する。Issue 群が触れるファイル集合の積（重なり）で独立性を判定し、環境を整備する。

    - **独立（積が空）**: Issue ごとに固有の環境（ブランチ・worktree・`RUN_DIR`）を `git-flow` スキルに従って整備する。Issue 単位の Planner→Generator→Evaluator パイプラインを手順2以降で**並列**に起動する。各パイプラインは独立した 3 値判定ループを PASS まで回し、それぞれ独立した PR を生み、対応 Issue をクローズする。

    - **重なる（積が非空）**: 並列に別ブランチで走らせると統合不能なコンフリクトを生む。重なる Issue 群を単一ブランチ・単一 PR に束ね、`git-flow` スキルに従って共通の環境（ブランチ・worktree・`RUN_DIR`）を整備する。Planner のファイル軸チャンク分割でこの重なりを吸収する。

    **実例**: Issue #46・#47・#49・#50 は `planner.md`・`run.md`・`README.md` を共有して重なるため、単一ブランチ `feat/resolve-open-issues` に束ね、ファイル軸チャンク M1/M2/M3（と簡素化 M4）で処理している。

    既に作業環境が構築済みの場合はそれを再利用する。

2. イテレーションの実行：サブエージェントを直列かつ同期的に呼び、作業を実行する。実行途中の作業を開始する場合は、実行が完了している最新イテレーションの次から再開する。

    1. Planner
    2. Generator（複数チャンク）
    3. Evaluator

    Trinityのオーケストレーターはコードに触れてはいけない。コードの変更は必ずGeneratorに移譲する。

    **設計分岐の確認と条件付き再起動**: Planner が `plan.md` 冒頭に `## 要確認の論点`（論点・選択肢・推奨の形）を書いた場合、Orchestrator はそのセクションを読み `AskUserQuestion` でユーザーに確認する。設計分岐の検出責務はコードを読み込んだ Planner に残り、確認と再起動判断のみが Orchestrator にある。

    確認後の Planner 再起動は**条件付き**である。

    | ユーザーの確定判断 | 動作 |
    | --- | --- |
    | Planner の推奨と**一致** | `plan.md` は既にその前提で書かれているため**再起動せずそのまま続行**する |
    | Planner の推奨と**食い違う** | 確定事項を添えて Planner を再起動し `plan.md` を上書きしてから続行する |

3. 次回イテレーションの実行判断：Evaluatorの評価により、以下の表に従って後続対応を判断、実行する。

    | 判定 | 動作 |
    | --- | --- |
    | `PASS` | ループ脱出。次の手順へ進む。 |
    | `NEEDS_REVISION` | 続行。Planner は次周回で `plan.md` を上書きする。 |
    | `FAIL` | 続行。Generator は修正作業を実施する。 |

4. Pull Requestの作成

    `git-flow` スキルに従い、Pull Requestを作成する。独立パイプラインが複数ある場合は Issue ごとに PR を作成する。重なる Issue 群を束ねた場合は単一の PR にまとめる。既存のPull Requestがある場合、そこに追加でPushして変更点をコメントとして記載する。

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

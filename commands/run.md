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

    要件を受け取る。Issue 番号が指定された場合は対象 Issue 群を識別し、変更同士が互いに影響するかを判断して環境を整備する。互いに影響しない変更は並列、影響する変更は直列で実装する。いずれも変更ごとに `git-flow` スキルに従って固有の環境（ブランチ・worktree・`RUN_DIR`）を整備し、各 Issue は独立した PR として残す。既に作業環境が構築済みの場合はそれを再利用する。

    環境構築の前に、`README.md` の前提条件節に列挙されたスキル・コマンド（git-flow スキル・code-review コマンド）が導入済みかを確認する。未導入のものがあれば、`/trinity:run` 起動を暗黙の許可とみなし、確認なしで自動セットアップを実施する（`~/.claude` への変更を含む）。

2. ループの実行：サブエージェントを直列かつ同期的に呼び、作業を実行する。途中から再開する場合は、`RUN_DIR` 内の成果物で到達点を判定する。**`code-review-<n>.md` が存在する最大の `n` を完了済みの最新ループとみなし、その次のループから再開する。**

    - `gen-<n>-task-*.md` はあるが `eval-<n>.md` が無いループ → Evaluator（サブ手順3）から続ける。
    - `eval-<n>.md` はあるが `code-review-<n>.md` が無いループ → code-review（サブ手順4）から続ける。
    - `code-review-<n>.md` が存在するループ → 完了済み。次のループへ進む。

    1. Planner
    2. Generator（複数タスク）:
        - Generator はタスクごとに新規起動する。タスクの実装が完了したら次のタスク用の Generator を新たに起動する。
        - Generator が検証失敗を自力で解決できずコミットを作らずに停止して報告した場合は、Evaluator へは進まない。その停止報告をもって手順3の判定表「Generator 停止（コミットなし）」の行に従って処理する。
        - すべてのタスクが完了したら、次のコマンドでループ内の最終コミット SHA を取得し Evaluator に渡す。

            ```bash
            LAST_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
            ```

    3. Evaluator
    4. code-review: Orchestrator（メイン会話）が子プロセスとして Claude をヘッドレス起動し `/code-review` を実行させる。レビュー範囲は `<merge-base>..HEAD`。

        ```bash
        BASE=$(git -C "${WORKTREE_DIR}" merge-base HEAD origin/main)
        ( cd "${WORKTREE_DIR}" \
          && env -u CLAUDECODE claude -p "/code-review ${BASE}..HEAD" --permission-mode bypassPermissions ) \
          > "${RUN_DIR}/code-review-${n}.md"
        ```

        非ゼロ終了・空出力・期待形式不一致はレビュー未実施として扱い再試行する。

    Trinityのオーケストレーターはコードに触れてはいけない。コードの変更は必ずGeneratorに移譲する。

    設計分岐の確認と Planner 再起動: Planner が `plan.md` 冒頭に `## 要確認の論点`（論点・選択肢・推奨の形）を書いた場合、Orchestrator はそのセクションを `AskUserQuestion` でユーザーへ提示する（内容は解釈・判定せず運搬する）。確認後、ユーザーの回答を入力に明示して Planner を必ず再起動する。再計画の要否は Planner が判断する。再起動された Planner は解決済みの論点を `## 要確認の論点` に再掲しない。

3. 次回ループの実行判断：Evaluator の評価・code-review の結果・Generator の停止報告により、以下の表に従って後続対応を判断、実行する。must-fix とは `/code-review` の出力に残った finding すべてを指す。Orchestrator は `code-review-<n>.md` の `### Code review` セクションに finding が1件以上あれば must-fix あり、「No issues found.」であれば must-fix なしと判定する。完了は Evaluator が PASS かつ must-fix なしの場合のみ。

    | 判定 | 動作 |
    | --- | --- |
    | Evaluator `PASS` かつ must-fix なし | ループ脱出。次の手順へ進む。 |
    | Evaluator `PASS` かつ must-fix あり | 続行。Generator が既存計画の範囲内で修正し、Evaluator 評価と code-review を再度回す。**2ループ連続で must-fix が残った場合**（指摘の同一性を問わず）は計画側の問題とみなし、`NEEDS_REVISION` と同様に Planner へ戻して再計画する。判定方法: 直前2ループの `code-review-<n>.md` にいずれも finding が1件以上あれば再計画トリガとする。 |
    | Evaluator `NEEDS_REVISION` | 続行。Planner は次周回で `plan.md` を上書きする。 |
    | Evaluator `FAIL` | 続行。Generator は修正作業を実施する。 |
    | Generator 停止（コミットなし） | Evaluator へは進まない。その停止報告を持って Planner を再計画（`NEEDS_REVISION` と同様）に回す。タスクを既存計画の範囲内で完了できないのは計画または方針側の問題とみなすためである。 |

4. Pull Requestの作成

    `git-flow` スキルに従い、Issue ごとに独立した PR を作成する。既存の PR がある場合はそこに追加で Push して変更点をコメントとして記載する。PR タイトルは `gh pr create --title` で渡し、本文は以下の見出し構成とする。

    ```markdown
    ## 目的

    ## 実装内容

    ## 変更点サマリ
    ```

5. マージ候補のヒアリング

    PR の URL をユーザーへ共有し、`AskUserQuestion`（`multiSelect=true`）で作成した PR 群をマージ候補として提示する。

    - **選択された PR**: `gh pr merge` でマージする。
    - **非選択の PR**: Other 欄の記入有無で判断する。記入があれば修正要望として手順2へ戻す。記入が無ければその PR を据え置く（マージしない）。

    修正用の独立した選択肢は設けない。修正内容は Other 欄で受ける。

6. 課題起票とクリーンアップの確認

    手順5の完了後、以下の最大4問を1回の `AskUserQuestion` コールでまとめて確認する。

    - **問1: 対象リポジトリへの課題起票**（ユーザーからの要望があった場合、もしくは対象リポジトリで改善すべき課題を見つけた場合のみ提示する）
      課題を `multiSelect=true` 形式で提示し、選択された課題を以下の `gh` コマンドで登録する。

        ```bash
        gh issue create --repo <owner/repo> --title "<title>" --body "<body>"
        ```

    - **問2: Trinity への課題起票**（ユーザーからの要望があった場合、もしくは Trinity 自体で改善すべき課題を見つけた場合のみ提示する）
      課題を `multiSelect=true` 形式で提示し、選択された課題を以下の `gh` コマンドで登録する。

        ```bash
        gh issue create --repo yjn279/trinity --title "<title>" --body "<body>"
        ```

        **自己適用（対象リポジトリが Trinity 自身）のケース**: 問1と問2は実質的に同じリポジトリへの起票になるため、1問に畳んで提示する。

    - **問3: クリーンアップ許可**（必ず独立した1問として提示する。他の確認と混同・誤承認を招かない設計にする）
      ユーザーから明示的な許可を受けたら、`git-flow` スキルに従い各環境（ブランチ・worktree）をクリーンアップする。対応する Issue は、手順5でマージ済みの PR に紐づくものは自動クローズ済みのため対象外とし、未マージのまま残っている PR に対応する Issue のみ手動でクローズする。また、`.trinity/` にある該当フォルダは削除する。

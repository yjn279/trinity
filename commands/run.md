---
description: "Harness for long-running tasks."
argument-hint: "<issue number(s) or a short requirement>"
---

# Instructions

Orchestrator（メイン会話）が実行する Trinity ハーネスの手続き定義である。Trinity の概念・設計思想・用語定義は `README.md` を正とする。各サブエージェントの責務・制約は `agents/` 以下の各定義ファイルを正とする。

1. 対象の識別と環境構築

    要件を受け取る。要件は Issue 番号で渡されることも、自由記述で渡されることもある。Issue 番号が指定された場合は対象 Issue 群を識別し、変更同士が互いに影響するかを判断して環境を整備する。

    互いに影響しない変更は、変更ごとに固有の環境（ブランチ・worktree・`RUN_DIR`）を `git-flow` スキルに従って整備し、手順2以降のパイプラインを並列に起動する。各パイプラインは独立した3値判定ループを PASS まで回し、それぞれ独立した PR を生む。影響する変更は、依存する変更の実装が完了してから後続を直列で実装する。この場合も `git-flow` スキルに従って変更ごとに環境を整備し、各 Issue は独立した PR として残し、統合（マージ）はしない。

    既に作業環境が構築済みの場合はそれを再利用する。

2. ループの実行：サブエージェントを直列かつ同期的に呼び、作業を実行する。途中から再開する場合は、`RUN_DIR` 内の成果物で到達点を判定する。ループの完了は code-review（サブ手順4）まで含めて初めて成立するため、**`code-review-<n>.md` が存在する最大の `n` を完了済みの最新ループとみなし、その次のループから再開する。** 再開点の判定は以下の3段階で行う。

    - `gen-<n>-task-*.md` はあるが `eval-<n>.md` が無いループは未完了であり、Evaluator（サブ手順3）から続ける。
    - `eval-<n>.md` はあるが `code-review-<n>.md` が無いループは未完了であり、code-review（サブ手順4）から続ける。
    - `code-review-<n>.md` が存在するループは完了済みであり、次のループへ進む。

    1. Planner
    2. Generator（複数タスク）: Generator はタスクごとに新規起動する。タスクの実装が完了したら次のタスク用の Generator を新たに起動する。Generator が検証失敗を自力で解決できずコミットを作らずに停止して報告した場合は、Evaluator へは進まず手順3の判定表「Generator 停止（コミットなし）」の行に従って処理する。すべてのタスクが完了したら、次のコマンドでループ内の最終コミット SHA を取得し Evaluator に渡す。

        ```bash
        LAST_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
        ```

    3. Evaluator
    4. code-review: Orchestrator（メイン会話）が子プロセスとして Claude をヘッドレス起動し、`WORKTREE_DIR` 内のコミット（ベースブランチとの diff）に対して `/code-review` を実行させる。理由は2つ。①スラッシュコマンドはサブエージェント（Planner・Generator・Evaluator）では動かず、メイン会話でしか実行できない。②`/code-review` は内部で複数エージェントを起動する重い機構であるため、子プロセス＋ファイル経由にして Orchestrator のコンテキストから隔離する。Orchestrator はレビュー結果ファイルだけを読む（生のレビュー過程はコンテキストに載せない）。

        レビュー対象は `<merge-base>..HEAD` のローカル diff を明示的に指定する。ベース分岐点は `git -C "$WORKTREE_DIR" merge-base HEAD origin/main` で求め、そこから HEAD までの全差分を `/code-review` の引数として渡す。これにより push 状態や upstream 設定に依存せず、PR の存在を前提とせず、当該ブランチの変更全体を一貫した範囲でレビューできる。レビュー範囲は毎ループ `<merge-base>..HEAD` の全差分（過去の承認済みコミットを含む）とする。これは意図的仕様であり、ループ間で既存コミットに後発バグが生じた場合も拾える。`/code-review` が内部で pre-existing issue を除外するため、再レビューによる不要な指摘増は抑えられる。サブシェルの `cd` は子プロセスにのみ作用し、Orchestrator やユーザーのチェックアウトには影響しない。

        ```bash
        BASE=$(git -C "${WORKTREE_DIR}" merge-base HEAD origin/main)
        ( cd "${WORKTREE_DIR}" \
          && env -u CLAUDECODE claude -p "/code-review ${BASE}..HEAD" --permission-mode bypassPermissions ) \
          > "${RUN_DIR}/code-review-${n}.md"
        ```

        子プロセスが非ゼロ終了した、出力ファイルが空の場合、または出力が期待形式を満たさない場合は、レビュー未実施として扱い、ループを脱出せず再試行する。空ファイルや終了コード0でも非正常な出力を「指摘なし」と誤読してはならない。期待形式とは「`### Code review` 見出し＋『Found N issues:』の番号付きリスト」または「`### Code review` 見出し＋『No issues found.』」であり、どちらでもない出力はゴミ出力として拒否する。

        再試行は最大3回まで行う。3回試行してもすべて失敗した場合は、code-review を打ち切り、ユーザーへ以下の内容を報告してエスカレーションする（ループを脱出して次手順へは進まない）。報告内容: ループ番号 `n`・試行回数・最後の失敗理由（非ゼロ終了／空出力／期待形式不一致）・`code-review-<n>.md` のパス。ユーザーの指示を待ち、自動で先へ進まない。

    Trinityのオーケストレーターはコードに触れてはいけない。コードの変更は必ずGeneratorに移譲する。

    設計分岐の確認と Planner 再起動: Planner が `plan.md` 冒頭に `## 要確認の論点`（論点・選択肢・推奨の形）を書いた場合、Orchestrator はそのセクションを読み `AskUserQuestion` でユーザーへ提示する。Orchestrator は論点の中身を解釈・判定せず、そのまま運搬する。確認後、Orchestrator はユーザーの回答（確定事項）を Planner 起動時の入力（プロンプト）に明示して添え、Planner を必ず再起動する（条件分岐なし）。再計画の要否は Planner が判断する。回答が Planner 自身の推奨どおりなら Planner は同じ plan を再出力すればよく、推奨と食い違えば plan を改める。いずれの場合も再起動された Planner は確定事項を反映し、解決済みの論点を `## 要確認の論点` に再掲しない。これにより同じ論点を再確認する無限ループを防ぐ。責務分界: 設計分岐の検出は（コードを読んだ）Planner、論点と回答の運搬・無条件の再起動は Orchestrator、再計画の要否判断は Planner。

3. 次回ループの実行判断：Evaluator の評価・code-review の結果・Generator の停止報告により、以下の表に従って後続対応を判断、実行する。ここで must-fix とは `/code-review` の出力に残った finding すべてを指す。`/code-review` は内部でスコア80未満・ニトピック・pre-existing issue を除外済みであるため、出力に残った finding は概ね実害ありとみなせる。Orchestrator は `code-review-<n>.md` を読み、`### Code review` セクションに finding（「Found N issues:」の番号付きリスト）が1件以上あれば must-fix ありと判定し、「No issues found.」であれば must-fix なしと判定する。Orchestrator は finding の有無だけを見ればよく、各指摘の性質（correctness か cleanup か等）を解釈しない。完了（ループ脱出して PR 作成へ進む）は Evaluator が PASS かつ must-fix が無い場合のみとする。なお、子プロセスの code-review は内部で6+エージェントを起動するため、評価1回あたりのコストが増える点に留意する。

    | 判定 | 動作 |
    | --- | --- |
    | Evaluator `PASS` かつ must-fix なし | ループ脱出。次の手順へ進む。 |
    | Evaluator `PASS` かつ must-fix あり | 続行。Generator が既存計画の範囲内で修正し、Evaluator 評価と code-review を再度回す。**2ループ連続で must-fix が残った場合**（指摘の同一性を問わず）は計画側の問題とみなし、`NEEDS_REVISION` と同様に Planner へ戻して再計画する。判定方法: 直前2ループの `code-review-<n>.md` にいずれも finding が1件以上あれば再計画トリガとする。 |
    | Evaluator `NEEDS_REVISION` | 続行。Planner は次周回で `plan.md` を上書きする。 |
    | Evaluator `FAIL` | 続行。Generator は修正作業を実施する。 |
    | Generator 停止（コミットなし） | Evaluator へは進まない。その停止報告を持って Planner を再計画（`NEEDS_REVISION` と同様）に回す。タスクを既存計画の範囲内で完了できないのは計画または方針側の問題とみなすためである。 |

4. Pull Requestの作成

    `git-flow` スキルに従い、Pull Requestを作成する。Issue ごとに独立した PR を作成する。影響する変更を直列に実装した場合も、各 Issue の PR は統合（マージ）せずそれぞれ独立した PR として残す。既存のPull Requestがある場合、そこに追加でPushして変更点をコメントとして記載する。

    PR タイトルは `gh pr create --title` で渡し、本文には含めない。本文は以下の見出し構成とする。

    ```markdown
    ## 目的

    ## 実装内容

    ## 変更点サマリ
    ```

5. 修正判断のヒアリング

    PRのURLをユーザーへ共有し、 `AskUserQuestion` で修正判断を仰ぐ。修正が必要な場合は手順2以降の手続きに従って修正を実行し、修正が必要が不要な場合は手順6に進む。

6. 対象リポジトリの課題起票

    ユーザーからの要望があった場合、もしくは**対象リポジトリ**で改善すべき課題を見つけた場合は、 `AskUserQuestion` で**対象リポジトリ**の課題起票を提案する。課題は `multiSelect=true` 形式ですべて提示し、そのうち実際に起票する課題をユーザーに選択してもらう。ユーザーが選択した課題は以下の `gh` コマンドでGitHub Issueとして登録する。

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


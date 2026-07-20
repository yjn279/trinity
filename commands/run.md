---
description: "Harness for long-running tasks."
argument-hint: "<issue number(s) or a short requirement>"
---

# Trinity

あなた（Orchestrator）はメイン会話のフォアグラウンドにいる。Planner・Generator・Evaluator の3アクターを束ね、Planner の計画に沿って Generator が実装し Evaluator が妥協なく評価する敵対的な往復を、Production-Ready まで回す。あなたが実装するのはユーザーの要件であり、その仕様は起動時の対話と各 Issue の `requirement.md` で定まる（この Trinity 自体の仕様書ではない）。

**あなたは一切コードに触れない。** 仕事は、自由形式の要件を解釈してユーザーと対話し、要件から依存・並列可否を**判断**して起動してよい Issue ごとに `${CLAUDE_PLUGIN_ROOT}/bin/trinity loop` を背景で起動し、監視すること。**判断はあなた、配管はシェル。** 内側ループ（`Plan → Generator → 道具 → Evaluator`）は Issue ごとの `loop` が1本の収束ループとして背景で回す。

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

後続 Issue（先行の完了を待つもの）は、先行 Issue の `status` が終端（passed/failed/error）に達したのを確認してから（手順4）、worktree を用意して backlog に追記し、手順3を再実行する。

既に作業環境が構築済みの場合はそれを再利用する。

### 3. Launch

`backlog.tsv` の各行につき、`<RUN_DIR>/status` が `passed` でなく、かつ `<RUN_DIR>/pid` が生存していない（`kill -0` が失敗する）Issue だけを起動する。生存していれば既に走っているので起動せず手順4の監視に回す。起動は `trinity loop` を Bash ツールの `run_in_background` で背景タスクとして立ち上げ、出力を `${RUN_DIR}/pipeline.out` へ追記する。

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/trinity" loop "${RUN_DIR}" "${WORKTREE_DIR}" "${BRANCH}" >> "${RUN_DIR}/pipeline.out" 2>&1
```

### 4. Monitor

起動した各 Issue の `<RUN_DIR>/status`・`<RUN_DIR>/ask/q` を直接ポーリングする。`status` がまだ無い Issue は起動直後の走行中として扱う。

| status | 対応 |
| :-- | :-- |
| （未作成）・`needs-input`／`passed`／`failed`／`error` 以外 | 走行中。しばらく間を置いてポーリングを続ける。 |
| `needs-input` | `<RUN_DIR>/ask/q`（Planner の `## 要確認の論点`）を読み、`AskUserQuestion` でユーザーに提示する。内容は解釈・判定せず運搬する。回答を `<RUN_DIR>/ask/a` に書く——`loop` のブロックが解け、Planner が確定事項を反映して再計画する。複数の Issue が同時に `needs-input` なら Issue ごとに直列で問う。書き終えたら同じ Issue のポーリングを続ける。`AskUserQuestion` を呼ぶのは常にあなた一人。 |
| `passed`／`failed`／`error` | 終端に到達。全 Issue が終端に達したら次へ進む。未起動の後続 Issue があれば worktree を用意して backlog に追記し、手順3を再実行する。 |

API 課金エラーやレートリミットで背景タスクが途中で止まっても、作業環境と `.trinity/<session>/` が残っていれば手順3を再実行すればよい。`loop` は段ごとのチェックポイント（`plan-<n>.md`・`gen-<n>-task-<i>.md`・`gen-<n>-revise.md`・`eval-<n>.md`）から完了済みの段・タスクをスキップして中断点から再開する。

`<RUN_DIR>/status` が `passed` の Issue は PR 作成へ進める。`failed`（ループ上限で未到達）・`error` の Issue は、`eval-*.md`・`pipeline.out` を読んで原因をユーザーに報告する。あなたはコードを直さない。

### 5. Pull Request

`passed` の Issue ごとに `git-flow` スキルに従って独立した PR を作成する。既存コードがすべてのタスクの要件をすでに満たしており、ブランチにデフォルトブランチとの差分が無い（全タスクが正当な変更不要だった）Issue は、PR を作らずその旨をユーザーに報告する。既存 PR があれば追加 Push し変更点をコメントする。タイトルは Conventional Commits 接頭辞付きの日本語命令形。本文は次の見出し構成にする。

```markdown
## 目的

## 実装内容

## 変更点サマリ
```

### 6. Merge & Wrap-up

作成した PR の URL をユーザーへ共有したうえで、マージ候補・課題起票・クリーンアップ許可を確認する。修正要望が入らない通常系では、これらを1回の `AskUserQuestion` コール（最大4問）にまとめられる。ただし修正要望が入った Issue がある場合、その Issue に紐づく課題起票は再収束後に改めて確認し、クリーンアップはセッション全体に対する単一の許可であるため redrive の保留が解消するまでセッション全体を遅延して改めて確認する——常に1回で完結するとは限らない。各問は以下の条件で提示する。

| 問い | 提示条件 | multiSelect |
| :-- | :-- | :-- |
| マージ候補の選択 | Git Issue が提示されたランのときだけ提示する。選択肢は作成済み PR 群、Other 欄は修正要望の受け口。複数 PR を提示する場合、Other 欄の修正要望がどの Issue／PR 宛てかを利用者が明記する。Git Issue から起票していない場合はこの問いを出さず、PR を作成したまま残してマージはユーザーに委ねる。 | true |
| 対象リポジトリへの課題起票 | 要望があった場合、または対象リポジトリで改善すべき課題を見つけた場合のみ提示する。 | true |
| Trinity への課題起票 | 要望があった場合、または Trinity 自体で改善すべき課題を見つけた場合のみ提示する。 | true |
| クリーンアップ許可 | 誤承認を避けるため必ず独立した1問として提示する。 | — |

回答は集めた順ではなく、以下の依存順で処理する。

1. **マージ**: 選択された PR を `gh pr merge` でマージする。マージ問の Other 欄に修正要望の記入があれば、その記入が指す Issue の PR は選択対象から除外し据え置く（マージしない）。他の独立した PR はこの時点で通常どおりマージが完了し、後続の修正確認（redrive）を待たない。
2. **課題起票**: 選択された課題を登録する。

   ```bash
   gh issue create --repo <owner/repo> --title "<title>" --body "<body>"
   gh issue create --repo yjn279/trinity --title "<title>" --body "<body>"
   ```

   ただし修正要望のあった Issue に紐づく課題起票はその場では登録せず、当該 Issue の再収束後に改めて確認する。
3. **修正確認（redrive）**: マージ問の Other 欄に記入があれば、その記入が指す Issue の `${RUN_DIR}/redrive` に修正要望テキストを書き、当該 Issue の `loop` を「3. Launch」の手順で再起動する。`loop` が `requirement.md` へ `## 修正要望（re-drive）` として反映した新しい計画で再収束する。この再起動も「4. Monitor」と同じ手順でポーリングし、終端に達するまで収束ラウンド1回分（`claude -p` 群による Plan → Generator → 道具 → Evaluator）のコストを要する——マージ・課題起票で他の Issue を先に済ませてあるため、この待機が他 Issue を人質にすることはない。当該 Issue が再収束（`passed`）に達したら、そのコミットを `git push` してブランチを更新する（同一ブランチのため既存 PR は自動更新される）。そのうえで当該 Issue 単独のマージ問を改めて `AskUserQuestion` で提示し、ユーザーの選択に従って本項目「マージ」の手続きへ戻ってマージまたは据え置きを判断する。
4. **クリーンアップ（最後・セッション単位）**: クリーンアップはセッション全体に対する単一の許可であり、Issue ごとに個別実行するものではない。修正確認（redrive）が発生した Issue がある間は、セッション全体のクリーンアップ許可を遅延し、当該 Issue の再収束・push・マージ再確認が完了してから改めてクリーンアップ許可（および「課題起票」で据え置いた課題起票）を問い直す。マージ結果に依存するため最後に処理する。許可を受けたら `git-flow` スキルに従い各環境（ブランチ・worktree）をクリーンアップし、`.trinity/<session>/` の該当フォルダを削除する。マージ済み PR に紐づく Issue は自動クローズ済みのため対象外とし、未マージのまま残る PR に対応する Issue のみ手動でクローズする。

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリの性質

これはアプリケーションではなく Claude Code プラグインである。実体はマークダウンのプロンプト定義と、それを駆動するシェルのハーネスである。`package.json` も依存関係もない。 `settings.json` は意図的にスキーマ宣言だけを置き、ツールの事前承認は利用側の `~/.claude/` ユーザー設定に委ねる。

構成は3層である。3つの agent 定義（ `agents/planner.md` ・ `agents/generator.md` ・ `agents/evaluator.md` ）、それを `claude -p` の子プロセスとして起動するシェルのハーネス（ `bin/trinity`・`lib/actors.sh` ）、そしてフォアグラウンドのオーケストレーター（ `commands/run.md` ）。対象プロジェクト側で `/trinity:run <要件>` を起動すると、Orchestrator が Issue 群を `backlog.tsv` に落とし、Issue ごとの背景パイプラインが `Plan → Generator → 道具 → Evaluator` を Production-Ready まで反復する。人がつくのはタスク投入直後——方針を確定するまで——であり、確定後は無人で走り切る。auto-mode で動かす前提の実装である。設計思想の網羅的な解説は `README.md` にあり、このファイルより詳しい。

## Product Management

最善の実装は、実装しないことである。機能追加には実装コストや保守コストが発生する。
ビルドトラップに陥らず本当に必要な機能のみを実装し、まずは実装しない解決策を検討する。

### 簡素化の進め方

1. **「シンプル」を着手前に複数観点で定義する。** 観点を1つに絞ると、表面積だけ削って認知負荷を上げる偽の改善を見抜けない。目標は方向（概念を減らす・重複を消す・挙動は保つ）とガードレール（確定仕様を割らない・検証を通す）で示し、ハード数値で縛らない。
2. **必要十分性を確定仕様に照らす。** `docs/requirements.md` を物差しに各要素がそこへ辿れるかを問い、辿れないものを削除候補にする。
3. **仕様外を削るときは一度確認する。** 「確定仕様にない」は「消すべき」ではない。運用上有用なアフォーダンス（監視性・再開など）のことがあるため、理由を添えて確認してから削る。
4. **単一の正を守る——重複側を削り、正典は残す。** 同じ事実が2文書にあるとき消すのは正典でない側。
5. **挙動を保ち、削った後に検証する。** 削った部品が解決していた失敗モードが、再発しないか・そもそも不要になったかで評価する。

### 簡素化のヒューリスティクス

- **仕様外のノブ・分岐・特例を削る。** 上限・タイムアウト・到達しない状態は、デフォルトで固定して無くせないかをまず問う。
- **判断と配管を分ける。** 「いくつ並列にするか」のような判断はシェルに埋め込まず、データ（`backlog.tsv` の行数）に逃がす。シェルは起動と監視に徹する。
- **footgun を削る。** 暗黙の前提（ヘッダ行の有無で壊れるパース等）は、注意書きを足すのでなく頑健化して特例知識を不要にする。

## 変更の検証方法

自動テストはない。シェルを書き換えたら最低限 `bash -n` と `shellcheck -S warning` を通す。挙動の確認は、このプラグインを入れた別プロジェクト（または使い捨ての作業ツリー）で実際に `/trinity:run` を小さな要件で回し、各アクターの出力と制御フローを観察して行う。書き換えた部品が解決していた失敗モードを再現できるか、あるいは不要になったかで評価する。

## アーキテクチャ

オーケストレーターとアクター3者で構成され、各アクターは固有のシステムプロンプトと新鮮なコンテキストを持つ。役割を1つに統合しないのは、コンテキストが膨らむほどドリフトが起き、評価者が自分のコードを甘く見るためである。Orchestrator はメイン会話のフォアグラウンドの Claude、Planner・Generator・Evaluator はシェルのハーネスが `claude -p` の子プロセスとして起動する。それぞれの責務と frontmatter を以下に示す。

| アクター | モデル | ツール | 責務 |
| :-- | :-- | :-- | :-- |
| Orchestrator | メイン会話 | — | 要件解釈・ユーザー対話・環境構築・背景パイプラインの dispatch と監視・PR 作成・確認・クリーンアップ |
| Planner | opus | 読み書き可 | 要件を `plan.md` と機械可読な `tasks.tsv` に展開しタスクに分割する |
| Generator | sonnet | 読み書き可 | 割り当てタスクを worktree 内で実装し1コミットする |
| Evaluator | sonnet | 読み取り専用 | コミットを4軸で独立評価し3値判定を書く |

frontmatter の `model:` と `tools:` は設計上の意味を持つため、安易に変えない。モデルはコストと推論負荷の割り当てである。ツールは責務の境界であり、とりわけ Evaluator が Write/Edit を持たない読み取り専用なのは、自分でコードを直せない制約が評価の独立性を担保するからである。各アクターの振る舞いの単一の正は `agents/<role>.md` であり、`lib/actors.sh` はその本文を frontmatter を除いて指示として注入する。プロンプトの二重管理はしない。

機械が下せる8割（実行検証・差分レビュー・整理）は、`bin/trinity loop` が Evaluator の前段で組み込みコマンド（`/code-review --fix`・`/simplify`・`/verify`）に委ねる。Evaluator はその出力を証拠として読み、削れない2割（要件適合・デザインの美・コードの美・要件妥当性）の判断にだけ集中する。`bin/trinity loop` の起動時、段ごとのチェックポイント（`plan-<n>.md`・`gen-<n>-task-<i>.md`・`gen-<n>-revise.md`・`eval-<n>.md`）から完了済みの段・タスクをスキップし、中断点から再開する。

アクターは互いのチャットコンテキストを見ず、受け渡しはすべてファイル経由で行う。`claude -p` の別プロセス境界がこの間接化を強制し、Evaluator の独立性を担保する。アクターをメイン会話のネイティブ subagent ではなく `claude -p` の子プロセスとして起動するのには、この独立性のほかに2つの構造的な理由がある。第一に、ネイティブ subagent は入れ子のサブエージェントを起動できないが、`claude -p` の子はフルの Claude Code セッションなので Planner・Generator・Evaluator が自分の作業の中でさらにサブエージェントを呼べる。第二に、long-running 前提のバックグラウンド実行が、メイン会話に張り付かない子プロセスだからこそ成り立つ。Orchestrator は段と段のあいだでコードを読み書きせず、`backlog.tsv` と `status`・`ask/` のファイルだけを介して背景パイプラインと通信する。通信の経路を以下に示す。

| 出力者 | 成果物 | 読む側 |
| :-- | :-- | :-- |
| Orchestrator | `${SESSION_DIR}/backlog.tsv`（薄い起動リスト：slug・worktree・branch・title） | `bin/trinity supervise` |
| Planner | `${RUN_DIR}/plan.md`・`${RUN_DIR}/tasks.tsv` | Generator・Evaluator・パイプライン |
| Generator | worktree 内の1コミット(SHA)と `${RUN_DIR}/gen-<n>-task-<i>.md` | Evaluator |
| 道具 | `${RUN_DIR}/review-<n>.md`・`simplify-<n>.md`・`verify-<n>.md` | Evaluator |
| Evaluator | `${RUN_DIR}/eval-<n>.md`（先頭行 `VERDICT:`） | Planner（次ループ）・パイプライン |
| パイプライン | `${RUN_DIR}/status`・`${RUN_DIR}/ask/q` | Orchestrator（監視・確認） |
| Orchestrator | `${RUN_DIR}/ask/a`（確認の回答） | パイプライン（Planner 再計画） |

## 守るべき不変条件

ハーネスの正しさは、複数ファイルにまたがる以下の規約に依存する。プロンプトを書き換えるときも崩さない。

| 規約 | 内容 |
| :-- | :-- |
| Orchestrator はコードに触れない | コードの読み書きは必ず Generator に委譲する。 |
| アクターは `claude -p` 経由 | Planner・Generator・Evaluator は `lib/actors.sh` の関数が `claude -p` の子プロセスとして起動する。アクターの振る舞いの単一の正は `agents/<role>.md`。 |
| worktree 隔離 | Generator・Evaluator は `git -C "${WORKTREE_DIR}" <cmd>` で操作し、 `cd` で代替しない。ユーザーのチェックアウトには触れない。 |
| 引用は worktree 相対 | `plan.md` ・ `eval-<n>.md` 内の `path:line` は `WORKTREE_DIR` 起点の相対パスで書く。 |
| 成果物の置き場所 | ラン成果物は対象プロジェクト側の `.trinity/<session>/<slug>/` に、`backlog.tsv` は `.trinity/<session>/` に出る。worktree は `.trinity/` の外に出る（配置規約は git-flow スキルに従う）。このリポジトリではない。 |
| 受け渡しは backlog.tsv とファイルチャネル | fan-out の境界は `backlog.tsv` 一枚。確認は `ask/q`・`ask/a`、進捗は `status` の各ファイルで橋渡しする。 |
| AskUserQuestion はフォアグラウンド限定 | `AskUserQuestion` を呼べるのは Orchestrator だけ。背景の Planner は `## 要確認の論点` を surface し、パイプラインが `needs-input` でブロックして Orchestrator の運搬を待つ。 |
| ログ保持 | このリポジトリに限り、`.trinity/` 配下のラン成果物（`trinity.log`・`backlog.tsv`・各ランの `plan.md`・`tasks.tsv`・ループごとのスナップショット `plan-*.md`・`eval-*.md`・`gen-*.md`・`review-*.md`・`status`・`planner-*.out`・`gen-*.out`・`evaluator-*.out`・`pipeline.out`）はデバッグのためクリーンアップで削除しない。 |
| 3値判定 | Evaluator は `eval-<n>.md` 先頭行 `VERDICT:` に `PASS` ・ `NEEDS_REVISION` ・ `FAIL` を返し、それぞれループ脱出・Planner 再計画・Generator 修正に対応する。ループ離脱は `PASS` だけで決まる。 |

## 編集時の規約

agent 定義とプロンプトを書き換える際の約束を以下に示す。

- ドキュメントとプロンプトはすべて日本語で書き、既存のトーンに合わせる。
- シェルは `bash`・`set -euo pipefail` を前提に書き、`shellcheck -S warning` を通す。アクターの振る舞いは `agents/<role>.md` を単一の正とし、`lib/actors.sh` に処理ロジックは寄せても振る舞いの指示は二重化しない。
- 配布メタデータを変えるときは `.claude-plugin/plugin.json` と `.claude-plugin/marketplace.json` の `name` を揃える。バージョンの単一の正は `plugin.json` の `version` フィールドであり、`version` の更新は release-please が `extra-files` 経由でリリース PR のマージ時に自動で行う（`marketplace.json` に `version` フィールドは持たせない）。現行バージョンの記録は `.release-please-manifest.json` が担う。リリース手順の詳細は `docs/release.md` を参照する。
- コミット・PR タイトルは Conventional Commits 接頭辞（`feat:`・`fix:`・`feat!:` など）を付けた日本語命令形で書く（例： `feat: release-please でリリースを自動化する`）。release-please はこの接頭辞からバージョン増分（patch / minor / major）を算出するため、接頭辞は必須である。PR 番号は squash merge が自動付与するため本文に手書きしない。

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

これはアプリケーションではなく Claude Code プラグインである。実体はマークダウンのプロンプト定義と、それを駆動するシェルのハーネスである。`package.json` も依存関係もない。 `settings.json` は意図的にスキーマ宣言だけを置き、ツールの事前承認は利用側の `~/.claude/` ユーザー設定に委ねる。

構成は3層である。3つの agent 定義（ `agents/planner.md` ・ `agents/generator.md` ・ `agents/evaluator.md` ）、それを `claude -p` の子プロセスとして起動するシェルのハーネス（ `bin/trinity`・`lib/actors.sh` ）、そしてフォアグラウンドのオーケストレーター（ `commands/run.md` ）。対象プロジェクト側で `/trinity:run <要件>` を起動すると、Orchestrator が Issue 群を `backlog.tsv` に落とし、Issue ごとの背景パイプラインが `Plan → Generator → 道具 → Evaluator` を Production-Ready まで反復する。人がつくのはタスク投入直後——方針を確定するまで——であり、確定後は無人で走り切る。auto-mode で動かす前提の実装である。設計思想の網羅的な解説は `README.md` にあり、このファイルより詳しい。

## Skills

Trinity の開発では以下のスキルを依存として用いる。仕様・設計・コード・ドキュメントを変更する前に必ず適用し、価値提供の最大化と要素数の最小化の両立で判断する。

- [product-management スキル](https://github.com/yjn279/.claude/tree/main/skills/product-management) — 機能追加の前に非実装の解決を検討し、削れる要素を削る。最善の実装は実装しないことであり、ビルドトラップを避ける。

## Verification

自動テストはない。シェルを書き換えたら最低限 `bash -n` と `shellcheck -S warning` を通す。挙動の確認は、このプラグインを入れた別プロジェクト（または使い捨ての作業ツリー）で実際に `/trinity:run` を小さな要件で回し、各アクターの出力と制御フローを観察して行う。書き換えた部品が解決していた失敗モードを再現できるか、あるいは不要になったかで評価する。

## Architecture

処理単位（セッション・パイプライン・ループ・タスク）の定義は `README.md` の [Processing Units](README.md#processing-units) 節を単一の正とする。

オーケストレーターとアクター3者で構成され、各アクターは固有のシステムプロンプトと新鮮なコンテキストを持つ。役割を1つに統合しないのは、コンテキストが膨らむほどドリフトが起き、評価者が自分のコードを甘く見るためである。Orchestrator はメイン会話のフォアグラウンドの Claude、Planner・Generator・Evaluator はシェルのハーネスが `claude -p` の子プロセスとして起動する。それぞれの責務と frontmatter を以下に示す。

| アクター | モデル | ツール | 責務 |
| :-- | :-- | :-- | :-- |
| Orchestrator | メイン会話 | — | 要件解釈・ユーザー対話・環境構築・背景パイプラインの dispatch と監視・PR 作成・確認・クリーンアップ |
| Planner | opus | 読み書き可 | 要件を `plan.md` と機械可読な `tasks.tsv` に展開しタスクに分割する |
| Generator | sonnet | 読み書き可 | 割り当てタスクを worktree 内で実装し1コミットする |
| Evaluator | sonnet | 読み取り専用 | コミットを4軸で独立評価し3値判定を書く |

frontmatter の `model:` と `tools:` は設計上の意味を持つため、安易に変えない。モデルはコストと推論負荷の割り当てである。ツールは責務の境界であり、とりわけ Evaluator が Write/Edit を持たない読み取り専用なのは、自分でコードを直せない制約が評価の独立性を担保するからである。各アクターの振る舞いの単一の正は `agents/<role>.md` であり、`lib/actors.sh` はその本文を frontmatter を除いて指示として注入する。プロンプトの二重管理はしない。この境界は二層の機構で enforce する。git は PATH レベルの shim `lib/git-shim/git` が exec 時点の argv で判定し（Planner・Evaluator は読み取り専用サブコマンドの allowlist、Generator は push・commit --amend/--no-verify の denylist）、Write/Edit（および NotebookEdit）は `lib/guard.sh` の PreToolUse フックが判定する。両方とも `trinity::claude` が per-actor に注入し、frontmatter の `tools:` はあくまで意図表現である。

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
| Orchestrator | `${RUN_DIR}/redrive`（修正要望テキスト） | パイプライン（`bin/trinity` の `loop` が消費し `requirement.md` へ追記） |
| `bin/trinity supervise` | `${RUN_DIR}/pid`（起動した `loop` の PID） | `bin/trinity supervise` 自身の再起動ガード（`pid_alive` の `kill -0`） |

## Invariants

ハーネスの正しさは、複数ファイルにまたがる以下の規約に依存する。プロンプトを書き換えるときも崩さない。

| 規約 | 内容 |
| :-- | :-- |
| Orchestrator はコードに触れない | コードの読み書きは必ず Generator に委譲する。 |
| アクターは `claude -p` 経由 | Planner・Generator・Evaluator は `lib/actors.sh` の関数が `claude -p` の子プロセスとして起動する。アクターの振る舞いの単一の正は `agents/<role>.md`。 |
| 権限は機構で enforce | 役割境界は二層で enforce する。git は PATH レベルの shim `lib/git-shim/git` が exec 時点の argv で判定し、Planner・Evaluator は読み取り専用サブコマンドの allowlist（deny-by-default）へ、Generator は push・commit --amend/--no-verify の denylist へ倒す。Write/Edit（および NotebookEdit）の許容範囲は `lib/guard.sh` の PreToolUse フックが判定する。`trinity::claude` が両方を per-actor に注入する。frontmatter の `tools:` は意図表現に留まり、同梱 `settings.json` はスキーマ宣言のみのまま変更しない。 |
| worktree 隔離 | Generator・Evaluator は `git -C "${WORKTREE_DIR}" <cmd>` で操作し、 `cd` で代替しない。ユーザーのチェックアウトには触れない。 |
| 引用は worktree 相対 | `plan.md` ・ `eval-<n>.md` 内の `path:line` は `WORKTREE_DIR` 起点の相対パスで書く。 |
| 成果物の置き場所 | ラン成果物は対象プロジェクト側の `.trinity/<session>/<slug>/` に、`backlog.tsv` は `.trinity/<session>/` に出る。worktree は `.trinity/` の外に出る（配置規約は git-flow スキルに従う）。このリポジトリではない。 |
| 受け渡しは backlog.tsv とファイルチャネル | fan-out の境界は `backlog.tsv` 一枚。確認は `ask/q`・`ask/a`、進捗は `status`、修正要望の再収束は `redrive` の各ファイルで橋渡しする。 |
| AskUserQuestion はフォアグラウンド限定 | `AskUserQuestion` を呼べるのは Orchestrator だけ。背景の Planner は `## 要確認の論点` を surface し、パイプラインが `needs-input` でブロックして Orchestrator の運搬を待つ。 |
| ログ保持 | このリポジトリに限り、`.trinity/` 配下のラン成果物（`trinity.log`・`backlog.tsv`・各ランの `plan.md`・`tasks.tsv`・ループごとのスナップショット `plan-*.md`・`eval-*.md`・`gen-*.md`・`review-*.md`・`simplify-*.md`・`verify-*.md`・`status`・`planner-*.out`・`gen-*.out`・`evaluator-*.out`・`pipeline.out`）はデバッグのためクリーンアップで削除しない。 |
| 3値判定 | Evaluator は `eval-<n>.md` 先頭行 `VERDICT:` に `PASS` ・ `NEEDS_REVISION` ・ `FAIL` を返し、それぞれループ脱出・Planner 再計画・Generator 修正に対応する。ループ離脱は `PASS` だけで決まる。 |

## Conventions

agent 定義とプロンプトを書き換える際の約束を以下に示す。

- 見出しは英語（1〜3語）で、本文と説明は日本語で書き、既存のトーンに合わせる。
- シェルは `bash`・`set -euo pipefail` を前提に書き、`shellcheck -S warning` を通す。アクターの振る舞いは `agents/<role>.md` を単一の正とし、`lib/actors.sh` に処理ロジックは寄せても振る舞いの指示は二重化しない。
- 配布メタデータを変えるときは `.claude-plugin/plugin.json` と `.claude-plugin/marketplace.json` の `name` を揃える。バージョンの単一の正は `plugin.json` の `version` フィールドであり、`version` の更新は release-please が `extra-files` 経由でリリース PR のマージ時に自動で行う（`marketplace.json` に `version` フィールドは持たせない）。現行バージョンの記録は `.release-please-manifest.json` が担う。リリース手順の詳細は `docs/release.md` を参照する。
- コミット・PR タイトルは Conventional Commits 接頭辞（`feat:`・`fix:`・`feat!:` など）を付けた日本語命令形で書く（例： `feat: release-please でリリースを自動化する`）。release-please はこの接頭辞からバージョン増分（patch / minor / major）を算出するため、接頭辞は必須である。PR 番号は squash merge が自動付与するため本文に手書きしない。

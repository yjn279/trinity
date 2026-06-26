# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## このリポジトリの性質

これはアプリケーションではなく Claude Code プラグインである。実体はマークダウンのプロンプト定義であり、ビルド・Lint・テストのツールチェーンを持たない。 `package.json` も依存関係もない。 `settings.json` は意図的にスキーマ宣言だけを置き、ツールの事前承認は利用側の `~/.claude/` ユーザー設定に委ねる。

構成は、3つの agent 定義（ `agents/planner.md` ・ `agents/generator.md` ・ `agents/evaluator.md` ）と、それらを駆動するオーケストレーター（ `commands/run.md` ）である。対象プロジェクト側で `/trinity:run <要件>` を起動すると、Planner → Generator → Evaluator が直列に回り、Evaluator が Production-Ready を承認するまで反復する。設計思想の網羅的な解説は `README.md` にあり、このファイルより詳しい。

## 最良の実装は、実装しないこと

足さずに済む道をまず探す。実装コストも保守コストもかけずに問題が消えるなら、それが最善である。

## 変更の検証方法

自動テストはない。挙動の確認は、このプラグインを入れた別プロジェクトで実際に `/trinity:run` を回し、各 agent の出力を観察して行う。プロンプトを書き換えたら、その部品が解決していた失敗モードを再現できるか、あるいは不要になったかで評価する。

## アーキテクチャ

処理単位（セッション・パイプライン・ループ・タスク）の定義は `README.md` の「[## Processing Units](README.md#processing-units)」節を単一の正とする。

オーケストレーターとサブエージェント3者で構成され、各 agent は固有のシステムプロンプトと新鮮なコンテキストを持つ。役割を1つに統合しないのは、コンテキストが膨らむほどドリフトが起き、評価者が自分のコードを甘く見るためである。Orchestrator はメイン会話の Claude、Planner・Generator・Evaluator はサブエージェントで、それぞれの責務と frontmatter を以下に示す。

| アクター | モデル | ツール | 責務 |
| :-- | :-- | :-- | :-- |
| Orchestrator | メイン会話 | — | 環境構築・各段の直列起動・PR 作成・確認・クリーンアップ |
| Planner | opus | 読み書き可 | 要件を `plan.md` に展開しタスクに分割する |
| Generator | sonnet | 読み書き可 | 割り当てタスクを worktree 内で実装し1コミットする |
| Evaluator | sonnet | 読み取り専用 | コミットを独立評価し判定を書く |

frontmatter の `model:` と `tools:` は設計上の意味を持つため、安易に変えない。モデルはコストと推論負荷の割り当てである。ツールは責務の境界であり、とりわけ Evaluator が Write/Edit を持たない読み取り専用なのは、自分でコードを直せない制約が評価の独立性を担保するからである。

サブエージェントは互いのチャットコンテキストを見ず、受け渡しはすべてファイル経由で行う。この間接化が Evaluator の独立性を構造的に強制する。Orchestrator は段と段のあいだでコードを読み書きせず、 `RUN_DIR` ・ `WORKTREE_DIR` ・ `BRANCH` のパスとコミット SHA だけを渡す。通信の経路を以下に示す。

| 出力者 | 成果物 | 読む側 |
| :-- | :-- | :-- |
| Planner | `${RUN_DIR}/plan.md` | Generator・Evaluator |
| Generator | worktree 内の1コミット(SHA)と `${RUN_DIR}/gen-<n>-task-<i>.md` | Evaluator |
| Evaluator | `${RUN_DIR}/eval-<n>.md` | Planner（次ループ）・Orchestrator |
| Orchestrator | `${RUN_DIR}/code-review-<n>.md`（子プロセスの `/code-review` 出力） | Orchestrator（次回ループ実行判断） |

## 守るべき不変条件

ハーネスの正しさは、複数ファイルにまたがる以下の規約に依存する。プロンプトを書き換えるときも崩さない。

| 規約 | 内容 |
| :-- | :-- |
| Orchestrator はコードに触れない | コードの読み書きは必ず Generator に委譲する。 |
| worktree 隔離 | Generator・Evaluator は `git -C "${WORKTREE_DIR}" <cmd>` で操作し、 `cd` で代替しない。ユーザーのチェックアウトには触れない。 |
| 引用は worktree 相対 | `plan.md` ・ `eval-<n>.md` 内の `path:line` は `WORKTREE_DIR` 起点の相対パスで書く。 |
| 成果物の置き場所 | `plan.md` ・ `eval-*.md` ・ `gen-*.md` 等のラン成果物は対象プロジェクト側の `.trinity/<run>/` に出る。worktree は `.trinity/` の外に出る（配置規約は git-flow スキルに従う）。このリポジトリではない。 |
| ログ保持 | このリポジトリに限り、`.trinity/` 配下のラン成果物（`trinity.log`・各ランの `plan.md`・退避した過去ループの `plan-*.md`・`eval-*.md`・`gen-*.md`・`code-review-*.md`）はデバッグのためクリーンアップで削除しない。 |
| 3値判定 | Evaluator は `PASS` ・ `NEEDS_REVISION` ・ `FAIL` を返し、それぞれループ脱出・Planner 再計画・Generator 修正に対応する。 |

## 編集時の規約

agent 定義とプロンプトを書き換える際の約束を以下に示す。

- ドキュメントとプロンプトはすべて日本語で書き、既存のトーンに合わせる。
- 配布メタデータを変えるときは `.claude-plugin/plugin.json` と `.claude-plugin/marketplace.json` の `name` を揃える。バージョンの単一の正は `plugin.json` の `version` フィールドであり、`version` の更新は release-please が `extra-files` 経由でリリース PR のマージ時に自動で行う（`marketplace.json` に `version` フィールドは持たせない）。現行バージョンの記録は `.release-please-manifest.json` が担う。リリース手順の詳細は `docs/release.md` を参照する。
- コミット・PR タイトルは Conventional Commits 接頭辞（`feat:`・`fix:`・`feat!:` など）を付けた日本語命令形で書く（例： `feat: release-please でリリースを自動化する`）。release-please はこの接頭辞からバージョン増分（patch / minor / major）を算出するため、接頭辞は必須である。PR 番号は squash merge が自動付与するため本文に手書きしない。

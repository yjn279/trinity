# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

これはアプリケーションではなく Claude Code プラグインである。実体はマークダウンのプロンプト定義と、それを駆動するシェルである。`package.json` も依存関係も無い。`settings.json` は意図的にスキーマ宣言だけを置き、ツールの事前承認は利用側の `~/.claude/` に委ねる。

構成は3層である。3つのアクター定義（`agents/planner.md`・`agents/generator.md`・`agents/evaluator.md`）、それを `claude -p` の子プロセスとして起動するシェル（`bin/trinity` と、役割境界を課すフック `lib/guard.sh`）、そしてフォアグラウンドの Orchestrator の手順書（`commands/run.md`）。設計の解説と確定仕様は `README.md` を単一の正とする。

仕様・設計・コード・ドキュメントを変更する前に、必ず [product-management スキル](https://github.com/yjn279/.claude/tree/main/skills/product-management)を適用し、価値提供の最大化と要素数の最小化の両立で判断する。最善の実装は実装しないことである。

## 構成

アクターは互いのチャット文脈を見ず、受け渡しはすべてファイルで行う。`claude -p` の別プロセス境界がこの間接化を強制し、Evaluator の独立性を担保する。経路を以下に示す。ラン成果物は対象プロジェクト側の `.trinity/<セッション>/<スラッグ>/`（`RUN_DIR`）に置かれ、worktree は `.trinity/` の外に切り出される。

| 出力者 | 成果物 | 読む側 |
| :-- | :-- | :-- |
| Orchestrator | `backlog.tsv`（作業単位ごとの slug・worktree・branch・title を実行順に記す索引） | Orchestrator 自身（起動・監視・再開のたびに読み返す） |
| Planner | `plan.md`・`tasks.tsv`（要件の更新を引き取った周は `requirement.md` も） | Generator・Evaluator・ハーネス |
| Generator | worktree 内のコミット（変更不要のときは無し）と完了レポート `gen-<n>-task-<i>.md` | Evaluator |
| 道具 | `review-<n>.md`・`simplify-<n>.md` | Evaluator |
| Evaluator | 判定本文（先頭行 `VERDICT:`）を標準出力で返し、ハーネスが `eval-<n>.md` として原子的に保存する | Planner（次ループ）・ハーネス |
| `loop` | `status`（`running` / `passed` / `failed` / `error`）と `pid`（起動時に原子的に主張し、終端で削除） | Orchestrator（監視・再起動の判定） |
| Orchestrator | `redrive`（修正要望の本文。`requirement.md` へ一度だけ取り込まれ、新しい `passed` か終端 `failed` まで残る） | `loop`（修正要望の再収束） |

## 不変条件

ハーネスの正しさは、複数ファイルにまたがる次の規約に依存する。プロンプトを書き換えるときも崩さない。

| 規約 | 内容 |
| :-- | :-- |
| Orchestrator はコードに触れない | コードの読み書きは必ず Generator に委譲する |
| アクターは `claude -p` 経由 | ふるまいの単一の正は `agents/<role>.md`。`bin/trinity` が本文を frontmatter を除いて指示として注入し、モデルも frontmatter の `model:` から読む。プロンプトとモデルの二重管理はしない |
| 権限は機構で enforce | 役割境界は `lib/guard.sh` の PreToolUse フック一本で課す。許否の詳細（git の役割別 allowlist・書き込み範囲）は `lib/guard.sh` が単一の正であり、frontmatter の `tools:` は意図の表明にとどまる。同梱 `settings.json` はスキーマ宣言のみのまま変更しない |
| worktree 隔離 | Generator・Evaluator は `git -C "${WORKTREE_DIR}" <cmd>` で操作し、`cd` で代替しない。ユーザーのチェックアウトには触れない |
| 引用は worktree 相対 | `plan.md`・`eval-<n>.md` 内の `path:line` は `WORKTREE_DIR` からの相対パスで書く |
| 確認は最初と最後だけ | `AskUserQuestion` を呼べるのはフォアグラウンドの Orchestrator だけで、起動時の設計確認と最後の受け入れ確認に限る。実行中のアクターはユーザーに確認せず、自分で判断して理由を成果物に残す |
| 3値判定 | Evaluator は本文の先頭行に `VERDICT:` として `PASS`・`NEEDS_REVISION`・`FAIL` のいずれかを返す。ループ離脱は `PASS` だけで決まり、道具による変更と要件の食い違いは常に `NEEDS_REVISION` に振り分ける（判断基準は `agents/evaluator.md` の「道具の逸脱」を正とする） |
| ログ保持 | このリポジトリに限り、`.trinity/` 配下のラン成果物はデバッグのため削除しない |

## 規約

ドキュメントとコードを書き換える際の約束を以下に示す。

- 見出しは日本語のシンプルな名詞とし、本文も日本語で書く。一般的な用語で記述し、造語を用いない。
- シェルは `bash`・`set -euo pipefail` を前提に書き、`shellcheck -S warning` を通す。処理ロジックはシェルに寄せてよいが、アクターのふるまいの指示は `agents/<role>.md` と二重化しない。
- コミット・PR タイトルは Conventional Commits 接頭辞（`feat:`・`fix:`・`feat!:` など）を付けた日本語命令形で書く（例: `feat: release-please でリリースを自動化する`）。release-please がこの接頭辞からバージョン増分を算出するため、接頭辞は必須である。
- 配布メタデータを変えるときは `.claude-plugin/plugin.json` と `.claude-plugin/marketplace.json` の `name` を揃える。バージョンの単一の正は `plugin.json` の `version` であり、手動で編集しない（`marketplace.json` には `version` を持たせない）。

## 検証

シェルを書き換えたら `bash -n` と `shellcheck -S warning` を通し、`bash tests/guard-git.sh` で役割境界の許否を確認する。挙動の確認は、このプラグインを入れた別プロジェクト（または使い捨ての作業ツリー）で `/trinity:run` を小さな要件で回し、各アクターの出力と制御フローを観察して行う。

## リリース

release-please が main への push を監視してリリース PR を作成・更新し、そのマージがそのままリリースになる（`plugin.json` の `version` 反映・タグ `vX.Y.Z`・GitHub Release がすべて自動で起きる）。増分はコミット接頭辞から決まり、`fix:` は patch、`feat:` は minor、`feat!:` または本文の `BREAKING CHANGE:` は major に対応する。CHANGELOG は生成せず、リリースノートは GitHub Releases から得る。リポジトリ設定では「Allow GitHub Actions to create and approve pull requests」を有効にしておく必要がある。

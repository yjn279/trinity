# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

これはアプリケーションではなく Claude Code プラグインである。実体はマークダウンのプロンプト定義とシェルであり、依存関係も設定も持たない（`settings.json` はスキーマ宣言のみのまま変更しない）。

変更の前に必ず `/product-management` スキルを適用する。KPI は仕様の少なさ・条件分岐の少なさ・コードの少なさ・定数の少なさであり、最善の実装は実装しないことである。

## 参照

内容はそれぞれのファイルを単一の正とし、ここには重複して書かない。

| ファイル | 内容 |
| :-- | :-- |
| `README.md` | 設計と確定仕様 |
| `commands/run.md` | Orchestrator の手順（設計確認・実行・PR・受け入れ・後片付け） |
| `agents/<role>.md` | 各アクターのふるまいとモデル（frontmatter の `model:` をシェルが読む） |
| `scripts/loop.sh` | ループの制御（状態・再開・二重起動の防止）。仕組みはここのコメントを読む |
| `scripts/steps.sh` | ループの各段（計画・実装・修正・道具・評価）。`loop.sh` が読み込む |
| `scripts/guard.sh` | アクターの権限を制限するフック。許可・拒否の判断はここが正 |
| `scripts/test-guard.sh`・`scripts/test-loop.sh` | 権限の許可・拒否と、ループの通し動作のテスト |

## 規約

- 見出しは日本語のシンプルな名詞とし、本文も日本語・一般的な用語で書く。造語を用いない。
- シェルは `bash`・`set -euo pipefail` を前提に書く。変更したら `bash -n`・`shellcheck -S warning` と `scripts/test-*.sh` の両テストを通し、挙動はこのプラグインを入れた別プロジェクトで `/trinity:run` を小さく回して確認する。
- コミット・PR タイトルは Conventional Commits 接頭辞付きの日本語命令形で書く（例: `feat: release-please でリリースを自動化する`）。release-please が接頭辞から増分（`fix:` は patch、`feat:` は minor、`feat!:` は major）を算出し、リリース PR のマージでバージョン反映・タグ・GitHub Release まで自動で行う。`plugin.json` の `version` は手で編集しない。
- このリポジトリに限り、`.trinity/` 配下のラン成果物はデバッグのため削除しない。

# Release

Trinity のリリースは release-please による自動化で行う。main を監視した release-please が Conventional Commits の接頭辞からバージョン増分を自動算出し、リリース PR を育て続ける。そのリリース PR をマージした瞬間に、バージョン伝播・タグ `vX.Y.Z`・GitHub Release がすべて同時に起きる。後付けの書き戻しは存在しない。CHANGELOG は生成しない（`skip-changelog: true`）。リリースノートは GitHub Releases から得る。

## How to Release

1. **変更を Conventional Commits 形式でコミット・PR タイトルに付けて main にマージする。** release-please はコミットタイトルの接頭辞（`feat:`・`fix:` など）からバージョン増分を算出するため、接頭辞は必須である。
2. **release-please が自動でリリース PR を作成・更新する。** push to main をトリガーに `.github/workflows/release-please.yml` が起動し、次バージョン（例: `v0.2.0`）に上げた `plugin.json` の `version` を反映したリリース PR が GitHub 上に現れる（または既存 PR が更新される）。
3. **リリース内容を確認してリリース PR をマージする。** 収録されるコミット・PR の一覧を見て意図した変更が含まれているかをレビューする。問題なければリリース PR をマージする。
4. **タグ `vX.Y.Z` と GitHub Release が自動で作成される。** リリース PR のマージがそのままリリースとなる。追加の操作は不要である。

## Flow

```
main へ PR マージ
  → release-please が「リリース PR」を作成・更新
      (.release-please-manifest.json / .claude-plugin/plugin.json の version を bump)
  → リリース PR をマージ
      → タグ vX.Y.Z・GitHub Release が自動作成される
```

## Versioning

release-please はコミットタイトルの接頭辞から次バージョンを決定する。

| 接頭辞 | 増分 | Trinity における対象変更の例 |
| :-- | :-- | :-- |
| `fix:` | patch | プロンプトやドキュメントの軽微な修正・表現の整形・誤字訂正など、挙動・規約に影響しない変更 |
| `feat:` | minor | エージェントの役割・制約・ループ制御などの規約追加や挙動の改善。後方互換を保った新機能の追加 |
| `feat!:` または本文に `BREAKING CHANGE:` | major | エージェント構成や通信プロトコルの互換を壊す再設計。使い方・インターフェースが根本から変わる変更 |

Trinity の実体はマークダウンのプロンプト定義であり、バイナリやライブラリとは性質が異なる。上表の「Trinity における対象変更の例」を判断基準として接頭辞を選ぶ。

## Version Policy

プラグインキャッシュは `version` でキー管理される。変更を反映させるには `plugin.json` の `version` を上げる必要がある。

バージョンの単一の正は `.claude-plugin/plugin.json` の `version` フィールドである。`version` の更新は release-please が `extra-files`（json updater + `jsonpath: $.version`）経由でリリース PR のマージ時に自動で行う。`plugin.json` の `version` を手動で編集してはならない。

`.release-please-manifest.json` は release-please が現行バージョンを記録するためのファイルである（bookkeeping）。`.claude-plugin/marketplace.json` には `version` フィールドを持たせない。利用側は `marketplace.json` 経由で `trinity@main` を追従するため、リリース PR マージで main に入ったバージョンが自動的に反映される。

## Repository Setup

release-please action がリリース PR を作成するには、Settings → Actions → General で「Allow GitHub Actions to create and approve pull requests」を有効化する必要がある。この設定が無効のままでは action がリリース PR を作成できない。

なお、`GITHUB_TOKEN` で作成された Release・タグは下流ワークフローをトリガーしないという既知の制約がある。本リポジトリに下流依存はないため影響しない。

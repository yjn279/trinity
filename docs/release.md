# リリース運用

Trinity のリリースは GitHub Actions による自動化で行う。リリースの起点は GitHub 上での Release 公開であり、CI がバージョン書き戻しを担う。

## リリースの起こし方

GitHub 上でタグ `vX.Y.Z`（先頭 `v` + semver）を指定して Release を作成（publish）する。これがリリースの唯一の起点であり、CI が以降の version 反映を自動で行う。

## 自動リリースフロー

Release が publish されると `.github/workflows/release.yml` が起動し、以下の順序で動作する。

1. `main` を checkout する（`fetch-depth: 0`、`GITHUB_TOKEN` を使用）。
2. タグ名を `env:` 経由で受け取り、`vX.Y.Z` 形式（先頭 `v` + semver `MAJOR.MINOR.PATCH`）であることを検証する。形式が不正な場合はワークフローを失敗させ、書き込みを行わない。
3. 先頭 `v` を除いた `X.Y.Z` を抽出する。
4. `jq` で `.claude-plugin/plugin.json` の `version` を `X.Y.Z` に書き換え、`python3 -m json.tool` で JSON 妥当性を確認する。
5. 変更がある場合のみ `main` にコミットし push する。コミットメッセージに `[skip ci]` を含め、ワークフローの再帰起動を防ぐ。変更がなければ何もしない。

権限は `contents: write` のみ付与し、最小権限の原則を守る。

## semver 基準

Trinity の実体はマークダウンのプロンプト定義であり、バイナリやライブラリとは性質が異なる。以下の基準を適用する。

| バージョン | 対象となる変更 |
| :-- | :-- |
| `patch` | プロンプトやドキュメントの軽微な修正・表現の整形・誤字訂正など、挙動・規約に影響しない変更 |
| `minor` | エージェントの役割・制約・ループ制御などの規約追加や挙動の改善。後方互換を保った新機能の追加 |
| `major` | エージェント構成や通信プロトコルの互換を壊す再設計。使い方・インターフェースが根本から変わる変更 |

## バージョン管理の方針

プラグインキャッシュは `version` でキー管理される。変更を反映させるには `plugin.json` の `version` を上げる必要がある。

バージョンの単一の正は `.claude-plugin/plugin.json` の `version` フィールドである。`.claude-plugin/marketplace.json` には `version` フィールドを持たせない。利用側は `marketplace.json` 経由で `trinity@main` を追従するため、CI が main に書き戻したバージョンが自動的に反映される。

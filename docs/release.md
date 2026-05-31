# リリース運用

Trinity のリリースは GitHub Actions による自動化で行う。リリースの起点は GitHub 上での Release 公開であり、CI がバージョン書き戻しを担う。

## リリースの起こし方

マージ対象の Pull Request に bump 種別を示すラベルを付ける。

| ラベル | bump 種別 |
| :-- | :-- |
| `release:major` | major |
| `release:minor` | minor |
| `release:patch` | patch |

ラベルが付いていない場合は patch をデフォルトとする。

PR を main にマージすると、CI が `.claude-plugin/plugin.json` の `version` を semver に従って上げ、main にコミットし戻す。詳細な自動フロー（タグ・Release 生成）はチャンク2で追記する。

## semver 基準

Trinity の実体はマークダウンのプロンプト定義であり、バイナリやライブラリとは性質が異なる。以下の基準を適用する。

| バージョン | 対象となる変更 |
| :-- | :-- |
| `patch` | プロンプトやドキュメントの軽微な修正・表現の整形・誤字訂正など、挙動・規約に影響しない変更 |
| `minor` | エージェントの役割・制約・ループ制御などの規約追加や挙動の改善。後方互換を保った新機能の追加 |
| `major` | エージェント構成や通信プロトコルの互換を壊す再設計。使い方・インターフェースが根本から変わる変更 |

## バージョン管理の方針

プラグインキャッシュは `version` でキー管理される。変更を反映させるには `plugin.json` の `version` を上げる必要がある。

バージョンの単一の正は `.claude-plugin/plugin.json` の `version` フィールドである。`.claude-plugin/marketplace.json` には `version` フィールドを持たせない。

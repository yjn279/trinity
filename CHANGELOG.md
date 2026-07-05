# Changelog

## [0.4.0](https://github.com/yjn279/trinity/compare/v0.3.0...v0.4.0) (2026-07-05)


### ⚠ BREAKING CHANGES

* エージェント構成と通信プロトコルを再設計した。

### Features

* Milestone v0.3.0 — 前提自動セットアップ・マージ機能化・確認集約・用語参照 ([#73](https://github.com/yjn279/trinity/issues/73)) ([20ca016](https://github.com/yjn279/trinity/commit/20ca0163ad20d3bc5fcb231fe9290329fccdb5ff))
* 内側ループをシェルへ機械化し組み込みコマンドを Evaluator の道具へ再構築する ([4bf7ab5](https://github.com/yjn279/trinity/commit/4bf7ab5885f5f3b990cda3947884e952fdc46ded))

## [0.3.0](https://github.com/yjn279/trinity/compare/v0.2.0...v0.3.0) (2026-06-07)


### Features

* Planner に品質工程の必須規定を追加する ([#52](https://github.com/yjn279/trinity/issues/52)) ([b782c7f](https://github.com/yjn279/trinity/commit/b782c7f878e8bc0466e68d07a006a64e20dc9284))
* 複数 Issue の並列オーケストレーションを実装する ([#54](https://github.com/yjn279/trinity/issues/54)) ([c9f8c03](https://github.com/yjn279/trinity/commit/c9f8c0390b140645bdd5c041d2bb93d1c2037092))


### Bug Fixes

* code-review 段の固定 SHA とハーネスの整合性欠落を修正する ([#68](https://github.com/yjn279/trinity/issues/68)) ([0565e45](https://github.com/yjn279/trinity/commit/0565e458b0d99766e4edb3582840660f41c7df31))
* Planner の設計分岐確認フローを Orchestrator 側へ移す ([#53](https://github.com/yjn279/trinity/issues/53)) ([4cd0ea2](https://github.com/yjn279/trinity/commit/4cd0ea2b896b831c2de3ae3a68d091d7c725084b))

## [0.2.0](https://github.com/yjn279/trinity/compare/v0.1.0...v0.2.0) (2026-05-31)


### Features

* import trinity plugin from yjn279/.claude ([d765c95](https://github.com/yjn279/trinity/commit/d765c95652c2ddf9b01e627c217a60d4cf704acb))
* import trinity plugin from yjn279/.claude ([ae4983b](https://github.com/yjn279/trinity/commit/ae4983bea8a64b946211e9b614290aa4fea4d697))
* release-please でリリースを自動化する ([#44](https://github.com/yjn279/trinity/issues/44)) ([10d610d](https://github.com/yjn279/trinity/commit/10d610dc6992680bca95455abdeac22e8439da47)), closes [#40](https://github.com/yjn279/trinity/issues/40)
* **run:** add post-run-trinity-self-issue-suggestions step ([c3ea2c1](https://github.com/yjn279/trinity/commit/c3ea2c1576b88d8cecada35b7c8d9d22a0bb6eab))
* **run:** PASS後の起票候補ヒアリング段を commands/run.md に追加する ([5961d7a](https://github.com/yjn279/trinity/commit/5961d7af275cac4bb144caa3ead697060123b624))
* **run:** 最終出力に元々の取り組みタスク（要件）を簡潔に表示する [1.1/1] ([#27](https://github.com/yjn279/trinity/issues/27)) ([40b8c00](https://github.com/yjn279/trinity/commit/40b8c0010f8444fc7706f66a6a18c40b61de2f94))


### Bug Fixes

* **hooks:** generator chunk finished に文言更新 [1.3/3] ([91dac43](https://github.com/yjn279/trinity/commit/91dac43915f8887362595a08a6d96c0ef2506e8b))

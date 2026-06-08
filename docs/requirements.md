# Trinity 要求仕様

## 概要

Trinity は、Production-Ready 品質水準を満たすまで反復する長時間タスク向けハーネスである。Planner・Generator・Evaluator の3エージェントが連携し、要件から Pull Request 作成・クリーンアップまでをユーザーの介入を最小化して実行する。

本書は「ユーザー（Trinity を使う開発者）がコマンドを叩いたとき、何を入力でき・何が起き・何が返ってくるか」という要求粒度で Trinity の振る舞いを記述する。実装の詳細・ファイル責務の配置・agent ごとの手続きは、本書ではなく以下の既存ドキュメントに委ねる。

## スコープと既存ドキュメントとの役割分担

| ドキュメント | 担当する内容 |
| :-- | :-- |
| 本書（`docs/requirements.md`） | ユーザー要求粒度の仕様——何を入力でき・何が起き・何が返るかという外形的な振る舞い契約 |
| `README.md` | 設計思想・アーキテクチャの概念解説・Processing Units の定義・使い方の例示 |
| `CLAUDE.md` | Trinity プラグイン自体を編集する開発者向けの規約・不変条件・アーキテクチャ詳細 |
| `commands/run.md` | Orchestrator が実行する具体的な手順（環境構築・ループ制御・PR 作成・クリーンアップのステップ） |
| `agents/planner.md` | Planner エージェントのシステムプロンプト（計画の展開・タスク分割の手順） |
| `agents/generator.md` | Generator エージェントのシステムプロンプト（実装・コミット・検証の手順） |
| `agents/evaluator.md` | Evaluator エージェントのシステムプロンプト（独立評価・3値判定の手順） |

本書は要求事項の列挙に徹し、概念の深掘りは `README.md` へ、内部実装規約は `CLAUDE.md` へリンクで委譲する。主要な要求には、その根拠となる出典 PR 番号を括弧書きで併記する。

## 起動と入力

### 呼び出し形式

`/trinity:run <要件>` で起動する。要件は自然文の文字列でも Issue 番号でも指定できる（PR #36 #54）。

```shell
# 自然文で指定する
/trinity:run ユーザー設定ページにテーマトグルを追加する。

# Issue 番号で指定する
/trinity:run #12

# 複数の Issue 番号を同時に指定する
/trinity:run #12 #15 #20
```

### 複数 Issue の扱い

複数の Issue 番号を1回のコマンドで指定できる。Orchestrator は Issue 群が互いのファイル集合に影響するかを判定し、以下の方針で処理する（PR #54）。

- 独立（互いに影響しない）: Issue ごとに環境を整備して並列で処理する。
- 依存（いずれかが影響する）: 依存する変更の実装後に後続を直列で処理する。

いずれの場合も各 Issue は独立した PR として残る（PR #54）。

### 起動時の暗黙許可

`/trinity:run` を起動した時点で、次の操作をすべて許可したものとして扱う。途中で個別の確認は行わない。

- worktree の作成
- ブランチの push
- PR の作成

### 中断後の再開

API 課金エラーやレートリミットで処理が途中停止しても、作業環境（worktree・`RUN_DIR`）が残っていれば、引数なし（または同一引数）で `/trinity:run` を再実行すると続きから再開する。Orchestrator は `RUN_DIR` 内の成果物から到達点を自動判定し、完了済みのループはスキップする。

## 前提条件と自動セットアップ

### 前提となるスキル・コマンド

Trinity を動かすには、以下のスキルおよびコマンドが導入済みである必要がある。

- **git-flow スキル** — worktree の作成・ブランチ管理・PR 統合を担うスキル。Orchestrator はこのスキルに git 運用を委譲する。
- **code-review コマンド** — Orchestrator がループの別段として子プロセスで変更全体にコードレビューを実施するために使うコマンド。

### 未導入時の自動セットアップ

上記のスキル・コマンドが未導入の場合、Trinity は `/trinity:run` の起動を暗黙の許可とみなし、確認なしで自動セットアップを実施する（`~/.claude` への変更を含む）（PR #73）。

## 処理フローと判定

### 処理単位

Trinity は処理を4つの粒度で扱う（詳細は [README.md の Processing Units 節](../README.md#processing-units) を参照）。PR #66 で用語を統一し、PR #55 で可視化した。

| 粒度 | 説明 |
| :-- | :-- |
| セッション | `/trinity:run` の起動から PR 作成・課題起票・クリーンアップまでのコマンド1回の実行全体。複数のパイプラインを束ねる最上位の単位 |
| パイプライン | 1つの worktree で実行される処理系列。ループを反復して1つの PR を作成するまでの流れ |
| ループ | パイプライン内で繰り返される `Plan → Generator → Evaluator → /code-review` の1周 |
| タスク | 各 Generator が実施する1コミット単位の実装。独立して動作し単独で検証可能な最小実装単位 |

### ループの構成

各ループは `Plan → Generator → Evaluator → /code-review` の順で構成される。Generator は複数のタスクを順に実施し、最終タスクのコミット後に Evaluator が評価を行う。Evaluator の判定と code-review の結果をもとに、Orchestrator が次の動作を決定する。

### Evaluator の3値判定

Evaluator は `PASS` / `NEEDS_REVISION` / `FAIL` の3値で判定を返す（PR #37）。

| 判定 | 後続 |
| :-- | :-- |
| `PASS` | ループ脱出条件を確認し、満たしていれば PR 作成へ進む |
| `NEEDS_REVISION` | Planner が次周回で `plan.md` を上書きして再計画する |
| `FAIL` | Generator が既存計画の範囲内で修正する |

### ループ脱出条件

ループを脱出して PR 作成へ進むには、以下の2条件を両方満たす必要がある（PR #68）。

1. Evaluator の判定が `PASS` である
2. `/code-review` の出力に must-fix（残存 finding）がない

どちらか一方でも満たしていない場合はループを継続する。

### 2ループ連続 must-fix による再計画

Evaluator が `PASS` を返しても must-fix が残った状態が2ループ連続した場合、Orchestrator は計画側の問題とみなし `NEEDS_REVISION` と同様に Planner へ戻して再計画を行う（PR #68）。これは実装の修正だけでは解消できない指摘が繰り返される状況での無限ループを防ぐためである。

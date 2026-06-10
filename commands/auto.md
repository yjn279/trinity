---
description: "Autonomous development cycle from issue to release."
---

# Trinity Auto

Trinity Autoは、対象リポジトリの開発標準プロセス（Issue起票からリリースまで）を1サイクル分進めるオーケストレーター・コマンドです。`/loop /trinity:auto` として起動すると、開発プロセス全体が無人で駆動し続けます。

## Overview

1回の起動が1サイクルであり、出口に近いステージから順に処理して仕掛かりを滞留させない。サイクルは リリース → 統合 → トリアージ → 実装 → 起票 → 報告 の順に進む。

判断の正は対象リポジトリの2文書に置く。両文書が無いリポジトリでは自律運転を開始せず、文書の作成を案内して終了する。

- `docs/product.md`: プロダクトの軸。トリアージ・設計分岐・起票の採否はここと照合する。
- `docs/process.md`: 開発標準プロセス。マージ条件・優先度基準・ガードレールの規定値はここに従う。

`/loop` の間隔は省略してセルフペーシングに任せるか、 `/loop 30m /trinity:auto` のように固定間隔を指定する。

## Instructions

1. 観測: `docs/product.md` と `docs/process.md` を読み、`gh` で open Issues・open PRs・リリース PR・必須チェックの状態を収集する。前提（git-flow スキル・code-review コマンド）の確認とセットアップは `/trinity:run` と同じ規約に従う。

2. リリース段: release-please のリリース PR が存在すれば、`docs/process.md` のリリース基準（CHANGELOG の収録内容・バージョン増分の妥当性）を確認してマージする。基準を満たさない場合は理由を PR コメントに残して据え置く。

3. 統合段: リリース PR を除く open PR を作成が古い順に確認し、`docs/process.md` のマージ条件を満たすものを squash merge する。マージ後は `git-flow` スキルに従いブランチ・worktree をクリーンアップし、対応 Issue をクローズする。コンフリクトのある PR は該当 Issue のパイプラインを再開して Generator に解消を委譲する。人手の PR には触れず、報告にのみ載せる。

4. トリアージ段: `status` ラベルの無い open Issue を `docs/process.md` のトリアージ基準で `status: ready`（`priority` 付き）または `status: blocked`（理由コメント付き）に振り分ける。

5. 実装段: WIP 上限に空きがあれば実装を進める。`status: in-progress` で作業環境が残っている Issue の再開を新規着手より優先し、無ければ `status: ready` の最優先 Issue を1件選んで `status: in-progress` に付け替え、自動モードで `/trinity:run #N` を実行する。パイプラインが完走しなかった場合はその旨と原因を Issue にコメントで記録し、直前サイクルにも同様の記録があれば `status: blocked` へ送る。

6. 起票段: 直近のラン成果物に残った改善提案（Evaluator の持ち越し指摘・code-review の残指摘）と `docs/product.md` のロードマップから、起票条件（出典・軸照合・上限）を満たす課題を Issue として起票する。

7. 報告: サイクルの成果（リリース・マージ・着手・起票・blocked 送り）と、ガードレールへの抵触、次サイクルへの引き継ぎを要約して出力する。成果が何も無いサイクルはその旨だけを簡潔に報告して終了する。進捗ゼロのガードレールに達した場合は `/loop` の停止を提案する。

## Auto Mode

自動モードでは、`/trinity:run` がユーザーへ確認する各点を、`docs/product.md` と `docs/process.md` に基づく既定判断へ読み替える。対応を以下に示す。

| run.md の確認点 | 自動モードの既定判断 |
| :-- | :-- |
| 設計分岐の確認（`## 要確認の論点`） | `docs/product.md` の軸と照合して Planner の推奨案を採用し、採用理由を PR 本文に記録する。軸と矛盾する、または軸で判断できない場合は Issue を `status: blocked` にしてそのパイプラインを中止する |
| マージ候補のヒアリング | `docs/process.md` のマージ条件を満たす PR をマージし、満たさない PR は据え置く |
| 課題起票の確認 | 起票条件（出典・軸照合・上限）を満たす課題のみ自動起票する |
| クリーンアップ許可 | マージ済み PR の環境（ブランチ・worktree）をクリーンアップする。未マージ PR の環境は残す。ラン成果物（ `.trinity/` ）の扱いは対象リポジトリの規約に従う |

code-review の子プロセス起動が再試行しても失敗し続ける場合（実行環境の権限分類器による拒否を含む）は、Orchestrator が本会話で `/code-review` を直接実行し、出力を `${RUN_DIR}/code-review-<n>.md` に保存して続行する。

## Guardrails

ガードレール（WIP 上限・新規着手と自動起票の上限・失敗の隔離・進捗ゼロ・軸の専権）の規定値は `docs/process.md` の Automation 節にある。サイクル中に抵触した場合は処理を中断するのではなく、抵触したガードレールと理由を報告に明記して残りのステージを続行する。

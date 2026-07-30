# Trinity

Trinity は、計画・実装・評価を分業する3つのエージェント（Planner・Generator・Evaluator）で、長時間のエンジニアリングタスクを走り切る Claude Code プラグインである。`/trinity:run <要件>` で起動すると、隔離された worktree の中で実装とコミットを重ね、Evaluator が本番投入できる品質と認めるまで反復し、PR の作成からマージ・後片付けまで進める。

ユーザーが関わるのは、起動直後の設計確認と最後の受け入れ判断の2回だけである。その間に確認は無く、導入すれば設定なしで使える。

## 役割

計画・実装・評価を1つの文脈に同居させると、文脈が膨らむほど計画が実装の都合で書き換わり、評価者が自分の作品に甘くなる。Trinity は役割を分け、Orchestrator（`/trinity:run` を受け取ったメイン会話の Claude 自身）が残り3つの役割を、固有の指示と新鮮な文脈を持つ `claude -p` の別プロセスとして起動する。受け渡しはファイルだけで行い、Evaluator は差分も検証も自分で再導出するため、「自分の書いたコードに甘くなる」という単一エージェントの典型的な失敗が設計上起こらない。

| 役割 | モデル | 担当 |
| :-- | :-- | :-- |
| Orchestrator | メイン会話 | 要件の解釈・設計の確定・ループの起動と監視・PR 作成・受け入れ確認・後片付け |
| Planner | opus | 要件を、受け入れ基準付きの計画とタスク一覧に展開する |
| Generator | sonnet | 割り当てられたタスクを worktree の中で実装し、検証を通してコミットする |
| Evaluator | sonnet | コミットを4軸（要件適合・デザインの美・コードの美・要件妥当性）で独立に評価し、3値の判定を返す |

## 流れ

Orchestrator が作業単位ごとにブランチと worktree を切り、収束ループ（`scripts/loop.sh`）を1本ずつ直列に回す。機械的に直せる指摘は道具（`/code-review --fix`・`/simplify`）が差分につき一度だけ自動修正し、Evaluator は機械に委ねられない4軸の判断に集中する。

```mermaid
flowchart LR
  requirement[要件] --> orchestrator[Orchestrator]
  orchestrator --> plan
  subgraph loop[収束ループ]
    direction TB
    plan[計画] --> generate[実装]
    generate --> tools[道具]
    tools --> evaluate[評価]
    evaluate -->|再計画| plan
    evaluate -->|修正| generate
  end
  evaluate -->|合格| pullRequest[PR]
```

Evaluator の判定がループの継続と離脱を決める。

| 判定 | 動作 |
| :-- | :-- |
| `PASS` | 4軸すべてを満たす。ループを離脱して PR 作成へ進む |
| `NEEDS_REVISION` | 計画・要件が誤っている、または道具の変更が要件の記述と食い違う。Planner が要件の更新か挙動の回復かを自分で判断し、再計画する |
| `FAIL` | 計画は妥当。既存計画の範囲内で Generator が修正する |

## 仕様

確定している仕様を以下に示す。ここに無いものは実装の裁量である。

| 仕様 | 内容 |
| :-- | :-- |
| 処理フロー | 3アクター（Planner・Generator・Evaluator）と道具（`/code-review --fix`・`/simplify`）による検証で、1つの収束ループを回す |
| worktree 実行 | 作業は `git-flow` スキルで切り出した worktree の中で行う。複数の作業単位は直列に実行する |
| 確認 | 設計は起動時にフォアグラウンドの Orchestrator が `AskUserQuestion` で確定する。実行中はユーザーに確認しない |
| 子プロセス起動 | Planner・Generator・Evaluator は、作業のなかでさらにサブエージェントを呼べるよう、`claude -p` の子プロセスとして起動される |
| 柔軟性 | 複数 Issue・単発 Issue・Issue でないタスク・実施後の修正のいずれにも対応する |
| PR マージ | Git Issue が提示された場合は Issue ごとに独立した PR を作成し、`AskUserQuestion` で提示した候補のうちユーザーが選択したものをマージする |
| 課題起票 | 対象リポジトリと Trinity 本体それぞれの改善課題を `AskUserQuestion` で起票提案し、選択された課題を Issue として登録する |
| 再開 | 実行が中断（使用量上限・レートリミット・障害など）しても、到達済みの工程をやり直さず中断点から再開する |
| 後片付け | マージと課題起票の完了後、マージされた作業単位の環境（ブランチ・worktree・ラン成果物）をリモートを含めて削除する。マージされなかった単位はすべて残す |

## 前提

`bash`・`git`・`claude` CLI が PATH にあり、[git-flow スキル](https://github.com/yjn279/.claude/tree/main/skills/git-flow)・[code-review コマンド](https://github.com/anthropics/claude-code/tree/main/plugins/code-review)・`/simplify` が導入されていること。未導入のものは起動時に自動で検出し、確認なしでセットアップされる（`~/.claude` への変更を含む）。

## 使い方

要件は自由形式の文でも Issue 番号でもよい。複数 Issue は Issue ごとに独立したブランチ・worktree・PR を作り、1本ずつ直列に処理する。途中で停止しても、再度起動すれば中断点から再開する。

```shell
/trinity:run ユーザー設定ページにテーマトグルを追加する。
/trinity:run #12 #15 #20
```

## 参考

- Anthropic「Harness design for long-running apps」 https://www.anthropic.com/engineering/harness-design-long-running-apps
- Qiita「@nogataka 氏の解説記事」 https://qiita.com/nogataka/items/efe8eb9df612d2211221

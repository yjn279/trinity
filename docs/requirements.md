# Trinity Specification

本書は Trinity の確定済み仕様だけを記す。ここに無いものは未確定であり、「正」として固定しない。実装規約は [`CLAUDE.md`](../CLAUDE.md)、設計思想の網羅的な解説は [`README.md`](../README.md) を参照する。

## Specifications

ユーザーが確定と明言した仕様を以下に示す。各ノード間で受け渡すデータの形式は未確定であり、固定スキーマを「正」として刻まない。

| 仕様 | 内容 |
| :-- | :-- |
| 処理フロー | 3アクター（Planner・Generator・Evaluator）と Tools による検証で、1つの収束ループを回す |
| Worktree 実行 | 各作業単位を git-flow で切り出した独立した worktree の中で実行する。worktree は依存関係に応じて直列にも並列にも組める（README の Processing Flow の図を参照） |
| AskUserQuestion | 設計の分岐はフォアグラウンドの Orchestrator が `AskUserQuestion` で解消し、背景アクターは `ask/q`・`ask/a` のファイルチャネルを経由して間接的に確認する |
| サブエージェント起動 | Planner・Generator・Evaluator はそれぞれの作業のなかでさらにサブエージェントを呼べる |
| ワークフローの柔軟性 | 複数 Issue・単発 Issue・Issue でないタスク・実施後の修正のいずれにも対応する |
| PR マージ | Git Issue が提示された場合は、各 Issue を独立した PR として作成し、`AskUserQuestion` で提示したマージ候補のうちユーザーが選択したものをマージする |
| 課題起票 | 対象リポジトリと Trinity 本体それぞれの改善課題を `AskUserQuestion` で起票提案し、選択された課題を Issue として登録する |
| 中断からの再開 | 実行が中断（使用量上限・レートリミット・障害など）しても、到達済みの工程をやり直さず中断点から再開する |

## Policies

確定仕様から導かれる設計判断を以下に示す。これらはこのリポジトリの実装で確定している。

| 方針 | 内容 |
| :-- | :-- |
| `claude -p` ハーネスの維持 | アクター自身がサブエージェントを起動でき（ネイティブ subagent は入れ子起動ができない）、long-running 前提の背景実行が成り立つため、アクターは `claude -p` の子プロセスとして起動する |
| 判断は Orchestrator・配管はシェル | 依存関係・並列可否などの判断は LLM である Orchestrator が行い、worktree の背景起動・並列実行・進捗監視・イベント通知の機構はシェルに置く |
| 固定スキーマを刻まない | ノード間のデータ形式が未確定である以上、特定のスキーマや列定義を唯一の正とする記述は持ち込まない。パース契約に要る最小構造は実装で定め、仕様として固定化しない |

## Invariants

確定仕様から導かれる不変条件を以下に示す。これらはいかなる変更においても維持する。

| 不変条件 | 内容 |
| :-- | :-- |
| Orchestrator はコードに触れない | コードの読み書きは必ず Generator に委譲する |
| アクターは `claude -p` 経由 | 振る舞いの単一の正は `agents/<role>.md`。`lib/actors.sh` は本文を指示として注入する |
| worktree 隔離 | Generator・Evaluator は `git -C "${WORKTREE_DIR}"` で操作し、`cd` で代替しない |
| AskUserQuestion はフォアグラウンド限定 | 呼べるのは Orchestrator だけ。背景の Planner は `## 要確認の論点` で差し戻す |
| 3値判定 | Evaluator は `eval-<n>.md` 先頭行に `VERDICT: PASS|NEEDS_REVISION|FAIL` を返し、ループ離脱は `PASS` だけで決まる |

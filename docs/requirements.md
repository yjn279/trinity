# 要件定義書

本書は Trinity（Claude Code プラグイン）の要件を定義する。Trinity は「4アクター ＋ シェルのハーネス ＋ 組み込みコマンドの道具化」という体系で、エンジニアリングタスクを Production-Ready の品質水準で遂行する。実装の単一の正はコード（`agents/`・`bin/`・`lib/`・`commands/`）にあり、本書はその背後にある「何を」「なぜ」を要件として言語化する。設計思想の網羅的な解説は [`README.md`](../README.md)、実装規約は [`CLAUDE.md`](../CLAUDE.md) を参照する。

## 1. 背景と目的

### 1.1 背景

AIエージェントに長時間タスクを任せると、単一のコンテキストに計画・実装・評価が同居するほどドリフトが起きる。実装の途中で計画が書き換わり、評価者が自分の作品を甘く見て、探索のトークンが実装のトークンを圧迫する。これは1つのエージェントに役割を集約することの構造的な帰結である。

### 1.2 目的

Trinity は、Production-Ready の品質水準を満たしながらエンジニアリングタスクを自律遂行するハーネスを提供する。役割を分離した複数のアクターと、それを駆動するシェルのハーネスにより、上記のドリフトを設計上発生し得なくする。ユーザーが負う労働を「バックログの管理」と「成果を受け入れるかの判断」だけに縮約することを目的とする。

### 1.3 設計原則

| 原則 | 内容 |
| :-- | :-- |
| 役割分離 | 計画・実装・評価を別アクターに分け、各々に固有のシステムプロンプトと新鮮なコンテキストを与える。 |
| 評価者の独立 | Evaluator は読み取り専用かつ別プロセス境界に置き、「自分のコードに甘くなる」失敗モードを構造的に封じる。 |
| 機械化と判断の分離 | 機械が下せる8割（実行検証・差分レビュー・整理）は組み込みコマンドへ委ね、人間にしか下せない2割の判断にだけ希少な判断力を注ぐ。 |
| 制御フローの機械化 | Issue ごとの収束ループと fan-out の後段はシェルへ機械化し、フォアグラウンドの文脈を内側ループのトークンで汚さない。 |
| ファイルベースの受け渡し | アクター間の受け渡しはすべてファイル経由とし、プロセス境界で独立性を強制する。 |

## 2. スコープ

### 2.1 対象範囲

- `/trinity:run <要件>` の起動から、Issue 群の分解・並列実行・PR 作成・課題起票・クリーンアップまでの一連の流れ。
- 4アクター（Orchestrator・Planner・Generator・Evaluator）の責務と振る舞いの定義。
- Issue ごとの収束ループ（`Plan → Generator → 道具 → Evaluator`）を駆動するシェルのハーネス。
- 複数 Issue の依存解決つき並列オーケストレーション。
- ユーザー確認の二層化（intake 時のネイティブ確認と、計画時のファイルチャネル経由の確認）。

### 2.2 対象外

- 対象プロジェクトのコードそのものの仕様（Trinity は手段であり、生成物の中身は要件ではない）。
- PR のマージ・デプロイなど統合の最終承認（ユーザーの判断に委ねる）。
- Claude 以外のエージェント CLI への対応（移植の差し替え境界のみ定義し、実装はしない）。
- 自動テストスイートの提供（本リポジトリの性質上、検証は実走と静的解析で行う）。

## 3. 用語定義

粒度の大きい順に、Trinity が扱う処理単位を定義する。

| 用語 | 定義 |
| :-- | :-- |
| セッション | `/trinity:run` の起動から PR 作成・課題起票・クリーンアップまでの、コマンド1回の実行全体。複数のパイプラインを束ねる最上位の単位。 |
| パイプライン | 1つの worktree で実行される処理系列。ループを Production-Ready に達するまで繰り返し、1つの PR を作るまでの流れ。 |
| ループ | パイプライン内で繰り返される `Plan → Generator → 道具 → Evaluator` の1周。道具で機械的な8割を片付けた上で、Evaluator の3値判定が継続と離脱を決める。 |
| タスク | 各 Generator が実施する1コミット単位の実装。独立して動作し単独で検証可能な最小実装単位。 |
| 道具 | Evaluator の評価前段でパイプラインが回す組み込みコマンド（`/code-review --fix`・`/simplify`・`/verify`・`/run`）。機械的な8割を担う。 |

## 4. アクター（ステークホルダー）

| アクター | 実体 | モデル | ツール | 責務 |
| :-- | :-- | :-- | :-- | :-- |
| ユーザー | 人間 | — | — | 要件の提示、計画分岐・PR・課題・クリーンアップの判断。 |
| Orchestrator | メイン会話の Claude | メイン会話 | 対話・シェル起動 | 要件解釈・ユーザー対話・環境構築・背景パイプラインの dispatch と監視・PR 作成・確認・クリーンアップ。**コードには触れない。** |
| Planner | `claude -p` 子プロセス | opus | 読み書き可 | 要件を `plan.md` と機械可読な `tasks.tsv` に展開する（Issue ごと）。本番コードは書かない。 |
| Generator | `claude -p` 子プロセス | sonnet | 読み書き可 | 割り当てタスクを worktree 内で実装し、検証を通して1コミットする。 |
| Evaluator | `claude -p` 子プロセス | sonnet | 読み取り専用 | コミットを4軸で独立評価し、3値判定を書く。 |

## 5. 機能要件

### 5.1 Orchestrator（`commands/run.md`）

- FR-O-1 要件を Issue 番号または自由形式の文として受領する。設計が分岐するほどの曖昧さは、fan-out 前に `AskUserQuestion` で詰める。
- FR-O-2 要件を独立した Issue 群に分解し、Issue ごとに `git-flow` スキルでブランチと worktree を切り出し、`RUN_DIR` を作って `requirement.md` を書く。
- FR-O-3 `SESSION_DIR` に `backlog.tsv`（`slug <TAB> deps <TAB> worktree <TAB> branch <TAB> title`）を書く。互いに影響しない変更は `deps` を `-` にして並列化し、影響する変更は `deps` に先行 slug を入れて直列化する。
- FR-O-4 `trinity supervise` に `SESSION_DIR` を渡し、起動可能なパイプラインを背景起動する。
- FR-O-5 `trinity supervise` がイベント（`needs-input`・`unblocked`・`done`・`timeout`）まで待機して返す `STATUS` 表と `EVENT:` 行に従って対応し、`done` か `timeout` まで繰り返す。
- FR-O-6 `needs-input` では `ask/q` を読み、内容を解釈・判定せず `AskUserQuestion` で運搬し、回答を `ask/a` に書く。
- FR-O-7 `unblocked` では直列後続の worktree を用意し、`backlog.tsv` の `worktree` 列を埋めて fanout を再実行する。
- FR-O-8 `passed` の Issue ごとに独立した PR を作成する（マージはしない）。タイトルは Conventional Commits 接頭辞付きの日本語命令形、本文は `## 目的`・`## 実装内容`・`## 変更点サマリ`。
- FR-O-9 PR の URL を共有し、`AskUserQuestion` で修正要否・課題起票・クリーンアップを順に確認する。明示的許可を得てからクリーンアップする。

### 5.2 Planner（`agents/planner.md`）

- FR-P-1 `requirement.md` を入力に、`plan.md`（「何を」「なぜ」と受け入れ基準）と `tasks.tsv`（`index <TAB> title <TAB> files`）を出力する。両者のタスク分割は必ず一致させる。
- FR-P-2 実装を1コミット単位の独立検証可能な最小タスク `M` に分割し、最終タスクとして必ずリファクタリングを置く。
- FR-P-3 「どう実装するか」は Generator に委ね、計画は「何を」「なぜ」に限る。既存コード由来の根拠は `path:line`（worktree 相対）で引用する。
- FR-P-4 設計が分岐する曖昧さは `plan.md` 冒頭の `## 要確認の論点`（論点・選択肢・推奨）に明示する。自身は `AskUserQuestion` を呼ばない（headless では機能しない）。
- FR-P-5 再計画時、`eval-<n-1>.md` が要件妥当性の問題を指摘していれば、誤った要件のまま作り直さず `## 要確認の論点` でユーザーに差し戻す。
- FR-P-6 確定事項を添えて再起動された場合はそれを計画へ反映し、解決済みの論点を再掲しない（同一論点の無限ループ防止）。
- FR-P-7 worktree 内のコードは読むだけで編集しない。

### 5.3 Generator（`agents/generator.md`）

- FR-G-1 `plan.md` のうち割り当てられたタスク（`TaskIndex`/`TaskTitle`/`TaskFiles`）だけを実装する。計画外の機能・リファクタ・「ついでの改善」は加えない。
- FR-G-2 コミット前に検証チェーン（型 → Lint → ユニット → 必要なら UI スモーク）を回し、すべて通してからコミットする。
- FR-G-3 1タスク = 1コミット。`--no-verify`・`--amend`・force-push は禁止。push は Orchestrator の責務。
- FR-G-4 修正モードでは `eval-<n-1>.md` の指摘を既存計画の範囲内で直し、新規タスクは追加しない。
- FR-G-5 検証失敗を自力で直せない場合はコミットを作らず停止して報告する。
- FR-G-6 作業は `git -C "${WORKTREE_DIR}"` に徹し、`cd` で代替しない。`gen-<n>-task-<i>.md` にレポートを書く。

### 5.4 Evaluator（`agents/evaluator.md`）

- FR-E-1 Generator のコミットを次の4軸で評価する。**要件適合**・**デザインの美**・**コードの美**・**要件妥当性**。各軸が「Production-Ready を上回る」ことを必要条件とする。
- FR-E-2 証拠は自分で再導出する。差分は `git -C "${WORKTREE_DIR}" show` で読み、検証チェーンを自分で再実行する。道具の出力や Generator の PASS 主張を鵜呑みにしない。
- FR-E-3 全指摘に `path:line`（worktree 相対）の引用を添える。出典のない指摘は載せない。
- FR-E-4 各受け入れ基準を PASS/FAIL の二値で、計画全体に対して判定する。一度出した指摘を黙って取り下げない。
- FR-E-5 `eval-<n>.md` の**先頭行**を `VERDICT: <PASS|NEEDS_REVISION|FAIL>` とする（パイプラインがこの1行を信号として読む）。
- FR-E-6 コードを書かない・編集しない・コミットしない。worktree は読み取り専用で見る。

### 5.5 ハーネス（`bin/`・`lib/`）

- FR-H-1 `lib/actors.sh` は各アクターを headless な `claude -p`（`bypassPermissions`、`CLAUDECODE` を外す）の子プロセスとして起動し、振る舞いの指示は `agents/<role>.md` の本文を frontmatter を除いて注入する（プロンプトの二重管理をしない）。
- FR-H-2 `bin/trinity loop <RUN_DIR> <WORKTREE_DIR> <BRANCH>` は1 Issue の収束ループを駆動する。`plan → generate → tools → evaluate` を最大 `TRINITY_MAX_LOOPS`（既定5）回繰り返し、`VERDICT` に応じて分岐する。
- FR-H-3 `bin/trinity supervise <SESSION_DIR>` は `backlog.tsv` を読み、依存が満たされ worktree が用意できた Issue を、並列上限 `TRINITY_MAX_PARALLEL`（既定3）の範囲で背景起動する。起動後は手当てが要るイベントまでブロックして待ち、`STATUS` 表と `EVENT:` 行を返す。受け渡し境界は `backlog.tsv` 一枚。`unblocked` は空きスロットがあるときだけ通知する。
- FR-H-4 パイプラインは状態を `RUN_DIR/status` に1語で出力する（`planning`・`generating`・`reviewing`・`evaluating`・`needs-input`・`queued`・`passed`・`needs-revision`・`failed`・`error`）。Orchestrator はこの1ファイルだけで進捗を把握できる。
- FR-H-5 挙動の確認は、自明な要件を使い捨ての作業ツリーで実際に走らせて行う（`bash -n`・`shellcheck -S warning` の静的検査と実走）。

### 5.6 道具（組み込みコマンドの道具化）

- FR-T-1 Evaluator の前段で `/code-review --fix` と `/simplify` を回し、差分の機械的な指摘を自動修正してコミットする。
- FR-T-2 `/verify`・`/run` で挙動の証拠を `verify-<n>.md` に残す。
- FR-T-3 道具の出力（`review-<n>.md`・`simplify-<n>.md`・`verify-<n>.md`）は Evaluator が証拠として読むものであり、判定そのものではない。Evaluator 自身は道具を呼ばない。

### 5.7 3値判定とループ制御

| 判定 | 条件 | 後続 |
| :-- | :-- | :-- |
| `PASS` | 4軸すべてが PASS、全受け入れ基準を満たす。 | ループを離脱して PR 作成へ。 |
| `NEEDS_REVISION` | 計画・要件自体が誤り、または再計画が必要なほど乖離。とくに要件妥当性が FAIL。 | Planner が再計画。要件が疑わしければ `## 要確認の論点` で差し戻す。 |
| `FAIL` | 不合格の指摘はあるが計画は妥当で、既存計画の範囲内で直せる。 | Generator が修正する。 |

- FR-J-1 ループの離脱は Evaluator の `PASS` だけで決まる。
- FR-J-2 `TRINITY_MAX_LOOPS` 回で `PASS` に至らなければ `failed` で終え、原因を残す。

### 5.8 ユーザー確認の二層化

- FR-A-1 要件レベルの曖昧さは intake 時に Orchestrator が `AskUserQuestion` でネイティブに解消する（前倒し）。
- FR-A-2 計画時に生じた設計分岐は、Planner が `## 要確認の論点` を surface し、パイプラインが `needs-input` でブロックする。Orchestrator が `AskUserQuestion` で運搬し、回答を `ask/a` に書いてブロックを解く。
- FR-A-3 `AskUserQuestion` を呼べるのは常にフォアグラウンドの Orchestrator だけ。

## 6. 通信・データフロー要件

アクターは互いのチャットコンテキストを見ず、受け渡しはすべてファイル経由で行う。

| 出力者 | 成果物 | 読む側 |
| :-- | :-- | :-- |
| Orchestrator | `SESSION_DIR/backlog.tsv` | `bin/trinity supervise` |
| Planner | `RUN_DIR/plan.md`・`tasks.tsv` | Generator・Evaluator・パイプライン |
| Generator | worktree の1コミット（SHA）・`gen-<n>-task-<i>.md` | Evaluator |
| 道具 | `review-<n>.md`・`simplify-<n>.md`・`verify-<n>.md` | Evaluator |
| Evaluator | `eval-<n>.md`（先頭行 `VERDICT:`） | Planner（次ループ）・パイプライン |
| パイプライン | `RUN_DIR/status`・`RUN_DIR/ask/q` | Orchestrator（監視・確認） |
| Orchestrator | `RUN_DIR/ask/a` | パイプライン（Planner 再計画） |

## 7. 非機能要件

| 区分 | 要件 |
| :-- | :-- |
| 独立性 | Evaluator は別プロセス・読み取り専用とし、Generator のチャット文脈や内部推論を受け取らない。差分・検証は自分で再導出する。 |
| 隔離 | Generator・Evaluator は worktree 内に閉じ、ユーザーのチェックアウトに触れない。worktree は `.trinity/` の外に切り出す。 |
| 安全性 | `AskUserQuestion` はフォアグラウンド限定。push・PR・クリーンアップは Orchestrator がユーザー許可の範囲で行う。 |
| 可観測性 | 各ランの成果物（`plan.md`・`tasks.tsv`・`eval-*.md`・`gen-*.md`・`review-*.md`・`status`・`trinity.log` 等）を `.trinity/<session>/<slug>/` に残し、デバッグ可能にする。 |
| 並列性 | 独立 Issue を `TRINITY_MAX_PARALLEL` の範囲で並列実行し、依存 Issue は依存解決後に直列起動する。 |
| 拡張性・移植性 | アクター呼び出しを `lib/actors.sh` に閉じ、別エージェント CLI へ寄せる際の差し替え境界をここに集約する。 |
| 国際化 | ドキュメントとプロンプトはすべて日本語で書き、既存のトーンに合わせる。 |

## 8. 制約条件・前提条件

### 8.1 前提

- `bash`・`git`・`claude` CLI が PATH にあり、`bin/` のシェルスクリプトに実行可能ビットが立っていること。
- [git-flow スキル](https://github.com/yjn279/.claude/tree/main/skills/git-flow)（worktree 作成・ブランチ管理・PR 統合）がインストール済みであること。
- [code-review コマンド](https://github.com/anthropics/claude-code/tree/main/plugins/code-review) と `/simplify`・`/verify`・`/run` が利用可能であること。
- 現状のターゲットは Claude（`claude -p`）。

### 8.2 制約

- Trinity はアプリケーションではなく Claude Code プラグインであり、`package.json` も依存関係も持たない。実体はマークダウンのプロンプト定義とシェルのハーネスである。
- バージョンの単一の正は `.claude-plugin/plugin.json` の `version` であり、release-please が自動更新する。手動編集しない（詳細は [`docs/release.md`](release.md)）。
- 既知の制約として、ゲートされたセッションではネスト起動の `claude -p`（`bypassPermissions`）が安全分類器に拒否されうる。

## 9. 守るべき不変条件

ハーネスの正しさは複数ファイルにまたがる以下の規約に依存する。

| 規約 | 内容 |
| :-- | :-- |
| Orchestrator はコードに触れない | コードの読み書きは必ず Generator に委譲する。 |
| アクターは `claude -p` 経由 | 振る舞いの単一の正は `agents/<role>.md`。`lib/actors.sh` は本文を指示として注入する。 |
| worktree 隔離 | Generator・Evaluator は `git -C "${WORKTREE_DIR}"` で操作し、`cd` で代替しない。 |
| 引用は worktree 相対 | `plan.md`・`eval-<n>.md` の `path:line` は worktree 起点の相対パスで書く。 |
| 受け渡しは backlog.tsv とファイルチャネル | fan-out の境界は `backlog.tsv` 一枚。確認は `ask/q`・`ask/a`、進捗は `status`。 |
| AskUserQuestion はフォアグラウンド限定 | 呼べるのは Orchestrator だけ。背景の Planner は `## 要確認の論点` を surface する。 |
| 3値判定 | Evaluator は `eval-<n>.md` 先頭行 `VERDICT:` に判定を返し、ループ離脱は `PASS` だけで決まる。 |

## 10. 受け入れ基準

本要件を満たす実装は、次を満たす。

- AC-1 `/trinity:run <要件>` が単一 Issue を受領し、worktree 内で `Plan → Generator → 道具 → Evaluator` を反復して `PASS` に至り、独立した PR を1つ作成する。
- AC-2 複数 Issue を指定したとき、独立変更は並列に、依存変更は依存解決後に直列に処理し、それぞれ独立した PR を残す（マージしない）。
- AC-3 計画時に設計分岐が生じたとき、パイプラインが `needs-input` でブロックし、Orchestrator の `AskUserQuestion` の回答が `ask/a` 経由で反映されて再計画が進む。
- AC-4 `NEEDS_REVISION` で Planner 再計画、`FAIL` で Generator 修正、`PASS` でループ離脱という分岐が、`VERDICT` 行どおりに動く。
- AC-5 `bash -n` と `shellcheck -S warning` がクリーンで、自明な要件の実走で全制御フロー分岐が動作する。
- AC-6 各アクターが互いのチャットコンテキストを参照せず、受け渡しがすべてファイル経由で完結する。

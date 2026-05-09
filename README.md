# Trinity — Claude Code 用の3エージェント・ハーネス

Anthropic の Planner / Generator / Evaluator パターンを Claude Code のサブエージェント機能で実装したハーネスである。`/trinity:run <要件>` で起動し、隔離された git worktree で実装してコミットし、Evaluator が PASS を返した時点で push と PR 作成を自動で行う。その後 `AskUserQuestion` でマージ可否をユーザーに確認し、承認時はリモートマージとローカルクリーンアップまでを完結させる。

## 目次

1. [登場人物](#1-登場人物)
2. [起動から PR までのフロー](#2-起動から-pr-までのフロー)
3. [なぜ3エージェントに分けるのか](#3-なぜ3エージェントに分けるのか)
4. [ディレクトリ構成](#4-ディレクトリ構成)
5. [作業領域の隔離（worktree モデル）](#5-作業領域の隔離worktree-モデル)
6. [エージェント間の通信契約](#6-エージェント間の通信契約)
7. [モデル割り当て](#7-モデル割り当て)
8. [使い方](#8-使い方)
9. [評価軸（Evaluator）](#9-評価軸evaluator)
10. [設定の構成（settings.json）](#10-設定の構成settingsjson)
11. [ログ](#11-ログ)
12. [拡張・縮退の指針](#12-拡張縮退の指針)
13. [参考資料](#13-参考資料)

## 1. 登場人物

ハーネスは「ユーザーが書く4つの設定ファイル」と「ランタイムで動く5つのアクター」で構成される。

| 区分 | 名前 | 実体 | 責務 |
| --- | --- | --- | --- |
| 設定 | `plugin.json` | `trinity/.claude-plugin/plugin.json` | プラグイン名・バージョンの宣言 |
| 設定 | `settings.json` | `trinity/settings.json` | trinity 固有の事前承認ツール |
| 設定 | `hooks.json` | `trinity/hooks/hooks.json` | SessionStart / UserPromptSubmit / SubagentStop |
| 設定 | `/trinity:run` | `trinity/commands/run.md` | オーケストレーターのプロンプト |
| 設定 | `trinity:planner` | `trinity/agents/planner.md` | Planner のシステムプロンプト |
| 設定 | `trinity:generator` | `trinity/agents/generator.md` | Generator のシステムプロンプト |
| 設定 | `trinity:evaluator` | `trinity/agents/evaluator.md` | Evaluator のシステムプロンプト |
| アクター | UserPromptSubmit hook | shell（hooks.json） | プリフライト（git 状態の検証） |
| アクター | Orchestrator | Claude（メイン会話） | run ディレクトリと worktree の作成、各段の起動、最終化 |
| アクター | Planner | Claude サブエージェント（opus） | 要件 → `plan.md` |
| アクター | Generator | Claude サブエージェント（sonnet） | `plan.md` → worktree 内のコード＋コミット |
| アクター | Evaluator | Claude サブエージェント（sonnet） | diff＋`plan.md` → `eval-N.md`、判定 |

これらの関係を図にすると次のとおりである。

```shell
┌───────────────────────────────────────────────────────────────────────┐
│ User                                                                   │
│   /trinity:run [--max-iter=N] <1〜4文の要件>                                │
└────────────────────────────────────┬──────────────────────────────────┘
                                     ▼
                ┌─────────────────────────────────────┐
                │ UserPromptSubmit hook (shell)       │  settings.json
                │  · git リポジトリ判定                │
                │  · working tree clean を強制         │
                │  · BASE_BRANCH を stderr に表示      │
                └─────────────────┬───────────────────┘
                                  ▼
                ┌─────────────────────────────────────┐
                │ Orchestrator (/trinity:run)             │  commands/run.md
                │  · RUN_DIR と worktree を生成        │
                │  · 各エージェントを直列に起動        │
                │  · 最終 PASS で push＋PR 作成        │
                │  · AskUserQuestion でマージ確認      │
                │  · 承認時: マージ＋クリーンアップ    │
                └──┬──────────────┬──────────────┬────┘
                   ▼              ▼              ▼
            ┌──────────┐    ┌──────────┐   ┌──────────┐
            │ Planner  │    │Generator │   │Evaluator │
            │  opus    │    │  sonnet  │   │  sonnet  │
            └────┬─────┘    └────┬─────┘   └────┬─────┘
       plan.md ◀─┘               │              └─▶ eval-N.md
                  commit on ◀────┘
                  worktree
                                  ▼
   ┌────────────────────────────────────────────────────────────────┐
   │ .trinity/<TS>-<slug>/                                          │
   │  ├─ plan.md         ← Planner 出力                              │
   │  ├─ eval-1.md ...   ← Evaluator 出力                            │
   │  └─ worktree/       ← 隔離 git worktree                         │
   │       branch: trinity/<TS>-<slug>  (base: BASE_BRANCH)         │
   └────────────────────────────────────────────────────────────────┘
                                  │
                       PASS のときだけ
                                  ▼
                ┌─────────────────────────────────────┐
                │ git-pull-request (1 スキルで完結)   │
                │   push → create_pull_request        │
                │   base = BASE_BRANCH                │
                │   head = trinity/<TS>-<slug>        │
                └──────────────────┬──────────────────┘
                                   ▼
                ┌─────────────────────────────────────┐
                │ Orchestrator: AskUserQuestion       │
                │ マージしてクリーンアップまで？       │
                │   1. マージしてクリーンアップ (Recommended)│
                │   2. PR は残して改善項目を相談する   │
                └──────────────────┬──────────────────┘
                         承認時のみ ▼
                ┌─────────────────────────────────────┐
                │ git-merge                           │
                │ merge_pull_request (squash)         │
                │   + worktree remove + branch -D     │
                │   + rm -rf "$RUN_DIR"  (EXTRA_CLEANUP_PATHS)│
                └─────────────────────────────────────┘
                         否認時のみ ▼
                ┌─────────────────────────────────────┐
                │ AskUserQuestion: 改善項目ヒアリング │
                │   → Followup: <回答> を最終出力に   │
                └─────────────────────────────────────┘
```

Orchestrator は段と段のあいだでコードを自分で読んだり編集したりしない。受け渡しは `RUN_DIR` `WORKTREE_DIR` `BRANCH` のパスとコミット SHA だけにする。各エージェントが成果物（ファイル）から動くという原則がハーネスの本質である。

## 2. 起動から PR までのフロー

時系列で何が起きるかを示す。番号は図と本文で対応する。

```shell
  ① /trinity:run <要件>
        │
        ▼
  ② UserPromptSubmit hook
        ・git repo? clean? → BASE_BRANCH 確定
        │
        ▼
  ③ Orchestrator: run ディレクトリと worktree の生成 — git-worktree スキル
        ・RUN_DIR     = .trinity/<TS>-<slug>/
        ・BRANCH      = trinity/<TS>-<slug>     (base: BASE_BRANCH)
        ・WORKTREE_DIR = RUN_DIR/worktree/
        │
        ▼
  ④ ループ n = 1 .. MAX_ITER ────────────────────────────────────┐
        │                                                          │
        │  ④-a Planner   →  RUN_DIR/plan.md を書く（再計画時は上書き）│
        │  ④-b Generator →  WORKTREE_DIR でコードを書き 1 コミット    │
        │  ④-c Evaluator →  RUN_DIR/eval-<n>.md を書き判定を返す      │
        │                                                          │
        │       判定 ─── PASS ────────────────────▶ ループ脱出 → ⑤ │
        │       判定 ─── NEEDS_REVISION / FAIL ──▶ n を進めて続行 ─┘
        │
        │ n == MAX_ITER で PASS なし → ⑤ をスキップして報告のみ
        ▼
  ⑤ 最終化（PASS のときだけ）— git-pull-request スキル
        ・PR タイトル: plan.md の H1（70 文字切り詰め）
        ・PR 本文: plan.md の背景・ゴール・受け入れ基準 + eval-<n>.md の軸別スコア
        ・git -C "$WORKTREE_DIR" push -u origin "$BRANCH"
        ・mcp__github__create_pull_request
            base = BASE_BRANCH, head = BRANCH
        → PR_NUMBER / PR_URL を取得
        │
        ▼
  ⑥ マージ確認（AskUserQuestion — 1 回目）— Orchestrator の責務
        「PR #N (<URL>) を作成しました。マージしてクリーンアップまで進めますか？」
        選択肢: 「マージしてクリーンアップ (Recommended)」/ 「PR は残して改善項目を相談する」/ 「Other」
        │
        ├─ 承認 ──▶
  ⑦ マージ＋クリーンアップ（承認時のみ）— git-merge スキル
        ・mcp__github__merge_pull_request (squash)
        ・git -C "$WORKTREE_DIR" push origin --delete "$BRANCH"  # リモートブランチ削除
        ・git -C "$(pwd)" fetch --prune origin
        ・git -C "$(pwd)" worktree remove "$WORKTREE_DIR"
        ・git -C "$(pwd)" branch -D "$BRANCH"
        ・rm -rf "$RUN_DIR"  # EXTRA_CLEANUP_PATHS として渡した run ディレクトリを削除
        │
        └─ 否認 ──▶
  ⑦' 改善項目ヒアリング（否認時のみ）— Orchestrator の責務
        AskUserQuestion（2 回目）:「改善したい内容を教えてください」
        → 最終出力に Followup: <回答> を追加
        │
        ▼
  ⑧ ユーザーへの最終出力
        Trinity result / RunDir / Branch / Plan / Commit / Eval / Iters / PR / Merge / Cleanup
        否認時: + Followup: <改善項目>
```

各ステップの責務は次のとおりである。

| # | アクター | 入力 | 出力 |
| --- | --- | --- | --- |
| ① | User | — | スラッシュコマンド `/trinity:run ...` |
| ② | UserPromptSubmit hook | カレント git 状態 | プロンプト通過／exit 2 でブロック |
| ③ | Orchestrator + `git-worktree` | `REQUIREMENT`, `BASE_REF`, `REPO_ROOT` | `RUN_DIR`, `WORKTREE_DIR`, `BRANCH` |
| ④-a | Planner | 要件、必要なら直前 `eval-<n-1>.md` | `${RUN_DIR}/plan.md` |
| ④-b | Generator | `plan.md`、必要なら直前 `eval-<n-1>.md` | worktree 内の 1 コミット（SHA） |
| ④-c | Evaluator | `plan.md`、コミット SHA、Generator の検証レポート | `${RUN_DIR}/eval-<n>.md`、判定 |
| ⑤ | Orchestrator + `git-pull-request` | PASS 時のみ | push 済みブランチ、PR URL と番号 |
| ⑥ | Orchestrator | PR URL・番号 | `AskUserQuestion`（マージ可否確認、1 回目） |
| ⑦ | Orchestrator + `git-merge` | 承認時のみ | マージ済み PR、削除済み worktree と branch と `.trinity/<run>/` |
| ⑦' | Orchestrator | 否認時のみ | `AskUserQuestion`（改善項目ヒアリング、2 回目） |
| ⑧ | Orchestrator | — | 整形された結果サマリ（PR / Merge / Cleanup 行を含む、否認時は Followup 行も） |

## 3. なぜ3エージェントに分けるのか

1つのエージェントで計画・実装・評価をまとめてやると、コンテキストが膨らむほどドリフトが起きる。実装の途中で計画が書き換わり、評価者が自分の作品を甘く見て、探索のトークンが実装のトークンを圧迫する。役割を3つのサブエージェントに分け、それぞれに固有のシステムプロンプトと新鮮なコンテキストを与えることで、各段の集中を保ち、評価者の独立した懐疑性を担保する。

Evaluator の独立性は、ファイルベースの通信によって構造的に強制される。Evaluator は計画ファイルと git diff を読み、Generator のチャットコンテキストや内部推論は読まない。これによって「自分の書いたコードに甘くなる」という単一エージェントの典型的な失敗モードが、設計上発生し得なくなる。

## 4. ディレクトリ構成

エージェント定義とコマンドは `trinity/` プラグイン内に、ランタイム成果物は実行プロジェクトの `.trinity/` 以下に置く。前者はリポジトリにコミットし、後者は `.gitignore` で除外する。

```shell
trinity/
├── .claude-plugin/
│   └── plugin.json     # プラグイン宣言（name, version, author）
├── agents/
│   ├── planner.md      # opus  · 要件 → plan.md
│   ├── generator.md    # sonnet · plan.md → worktree 内のコード＋コミット
│   └── evaluator.md    # sonnet · diff＋plan.md → eval-N.md
├── commands/
│   └── run.md          # /trinity:run オーケストレーター（ループ規範・出力フォーマットを含む）
├── hooks/
│   └── hooks.json      # SessionStart / UserPromptSubmit / SubagentStop
├── skills/             # オーケストレーター用汎用スキル（Trinity 非依存）
│   ├── git-worktree/
│   │   └── SKILL.md    # 隔離 worktree の作成（要件文・base ref・リポジトリルートを受け取る）
│   ├── git-pull-request/
│   │   └── SKILL.md    # origin への push と PR 作成を一連フローで実行（入力: タイトル・本文のみ）
│   └── git-merge/
│       └── SKILL.md    # squash マージ＋クリーンアップ（承認が取れている前提で動く、入力: PR URL のみ）
├── settings.json       # trinity 固有の事前承認ツール
└── README.md           # 本ファイル

.trinity/                                   # 実行プロジェクト直下、SessionStart で hook が用意
├── trinity.log                             # 全 run 共通の時系列ログ
├── 20260429T153000Z-add-theme-toggle/      # run ディレクトリ
│   ├── plan.md                             # Planner 出力（イテレーション間で上書き）
│   ├── eval-1.md                           # Evaluator 出力（イテレーション 1）
│   ├── eval-2.md                           # 〃 （イテレーション 2）
│   └── worktree/                           # git worktree（branch: trinity/<TS>-<slug>）
└── 20260428T091200Z-fix-login-bug/
    ├── plan.md
    ├── eval-1.md
    └── worktree/
```

run ディレクトリ名は UTC 基本形式のタイムスタンプ（`YYYYMMDDTHHMMSSZ`）と、要件から派生した英字 kebab-case の slug を `-` で連結する。コロンを含まないので Windows でも安全に扱える。同一秒で衝突した場合は slug 末尾に `-2` `-3` などを付ける。

## 5. 作業領域の隔離（worktree モデル）

`/trinity:run` は起動時のブランチを `BASE_BRANCH` として記録し、それ以降このブランチには一切手を触れない。代わりに `BASE_BRANCH` から派生した新しいブランチ `trinity/<TS>-<slug>` を、別ディレクトリ `.trinity/<run>/worktree/` に git worktree として展開する。Generator はその中だけで読み書きとコミットを行う。

```shell
# 起動時に hook が確認した状態
BASE_BRANCH = main             ← ユーザーがいたブランチ。clean。

# Orchestrator が作る隔離環境
trinity/20260429T153000Z-add-theme-toggle  ← 新規ブランチ
  └─ checked out at  .trinity/20260429T153000Z-add-theme-toggle/worktree/
```

これがもたらす性質は次のとおりである。

- ユーザーの本来のチェックアウトは一切汚れない。Trinity 実行中も別の作業を続けられる。
- 複数の `/trinity:run` を並行で動かしてもお互いに踏み合わない。各 run は独立した worktree を持つ。
- worktree の後始末はユーザーの承認次第で行う。PASS 後に `AskUserQuestion` でマージを承認した場合は `/trinity:run` が自動でクリーンアップする（worktree、branch、`.trinity/<run>/` を削除する）。否認した場合はクリーンアップを行わず、代わりに改善項目のヒアリングを行う。
- 最終 PASS 後に push する対象は `trinity/<TS>-<slug>` ブランチであり、PR の base は `BASE_BRANCH` になる。

## 6. エージェント間の通信契約

サブエージェントは互いのチャットコンテキストを見ない。ファイルを介して受け渡しを行う。Orchestrator は絶対パスだけを各段に渡す。

| 出力者 | ファイル / 成果物 | 読む側 |
| --- | --- | --- |
| Planner | `${RUN_DIR}/plan.md` | Generator、Evaluator |
| Generator | `${WORKTREE_DIR}` 内の 1 コミット（SHA） | Evaluator |
| Evaluator | `${RUN_DIR}/eval-<n>.md` | Planner（次イテレーション）、Orchestrator（最終化時） |

引用ルールはハーネス全体で一貫させる。`plan.md` `eval-N.md` の中で示す `path:line` は **`WORKTREE_DIR` 起点の相対パス** で書く。Generator/Evaluator は同じ worktree を起点に読むためズレない。PR 本文に貼ったときもレビュアーがリポジトリ相対で読める。

## 7. モデル割り当て

軸となる配分は次のとおりである。各エージェントの frontmatter にある `model:` で個別に上書きできる。

| エージェント | モデル | 理由 |
| --- | --- | --- |
| Planner | opus | 漠然とした意図を二値の受け入れ基準に落とす、最も推論負荷の高い段 |
| Generator | sonnet | 仕様が明確な大量作業向き。コスト効率が良い |
| Evaluator | sonnet | 独立した懐疑性は Opus を要さない。Sonnet で十分かつ低コスト |

## 8. 使い方

代表的な呼び出しは次のとおりである。

```shell
/trinity:run ユーザー設定ページにテーマトグルを追加する。
/trinity:run --max-iter=5 認証モジュールを JWT からセッションCookie に移行する。
```

`MAX_ITER` の既定値は 15 である。短いタスクで素早く回したいときは `--max-iter=3` のように下げる。長時間で品質を追い込みたいタスクほど既定値が活きる構成になっている。

`/trinity:run` を起動した時点で、ユーザーはパイプライン全体（worktree 作成、ブランチ push、PR 作成）への明示的な許可を出したものとして扱う。PR 作成まではユーザー確認を取らずに進める。PR 作成後はマージの可否を `AskUserQuestion` で都度確認し、承認時のみリモートマージとクリーンアップを行う。NEEDS_REVISION / FAIL のまま `MAX_ITER` に達した場合は、push・PR 作成・マージ確認・クリーンアップのいずれも行わず、最新の評価レポートのパスを表示して停止する。黙って延々と繰り返さない。

## 9. 評価軸（Evaluator）

記事準拠の4軸を二値で採点する。

- **機能性**：コードが計画どおりに動くか
- **コード品質**：可読性、既存パターンとの整合、不当な `any` の不使用
- **ビジュアル設計**：UI の忠実度とアクセシビリティ。UI 変更がない場合は N/A
- **製品としての厚み**：エッジケース、空・エラー・ローディング状態、計画で指摘された競合状態

すべての指摘は `path:line` で根拠を示す。イテレーション N で出した指摘を N+1 で黙って消すことは禁止する。新しい証拠で「修正済み」を確認するか、未解決として持ち越すかのどちらかである。

判定は3値で出る。

- **PASS**：全受け入れ基準と全軸が PASS
- **NEEDS_REVISION**：FAIL があるが計画は正しく、Generator が直せる範囲
- **FAIL**：計画自体が誤っており、再計画が必要

## 10. 設定の構成（hooks.json と settings.json）

trinity 固有のフックと事前承認ツールはプラグイン配下に閉じている。汎用の dev ツール権限は親リポジトリ（`~/.claude/`）の `settings.json` に置く。

### フック（`trinity/hooks/hooks.json`）

| フック | タイミング | 役割 |
| --- | --- | --- |
| `SessionStart` | セッション開始時 | `.trinity/` の存在と `trinity.log` の用意 |
| `UserPromptSubmit` | プロンプト送信前 | `/trinity:run` を検出したら git repo＋clean を強制（ダメなら exit 2） |
| `SubagentStop` | サブエージェント終了時 | `trinity:generator` `trinity:evaluator` の終了時刻を `trinity.log` に追記 |

汎用の `PostToolUse`（agent/command 定義の YAML frontmatter 欠損警告）はプラグイン外、ルートの `settings.json` に置く。Trinity に閉じた挙動ではないからである。

`UserPromptSubmit` がプリフライトの責務を持つことが重要である。これは Claude ではなくハーネスが実行するので、`/trinity:run` が起動した瞬間に「git リポジトリ内かつ working tree が clean」が保証される。プロンプト側で再実装する必要はない。

### 事前承認ツール

trinity 固有分は `trinity/settings.json` に。

- worktree 操作：`git worktree`、`git -C <path> ...`
- 起動時の `mkdir -p`、ログの `cat .trinity/*`

汎用 dev ツール（`tsc --noEmit`、`eslint`、`vitest run`、`jest`、`pytest`、`ruff`、`mypy`、`git status/log/diff/show/rev-parse`、`ls`）はリポジトリトップの `settings.json` に置く。Trinity 以外でも使うので分けて管理する。

UI スモークの Playwright MCP は別途設定する。それ以外は実行時にプロンプトが出る。これは意図的である。破壊的なコマンドや珍しいコマンドは明示的な承認を必要とすべきだからである。

## 11. ログ

`.trinity/trinity.log` は全 run の時系列ログである。run ごとには分けず、各 run の境界は Orchestrator が書き込むヘッダ行で見分ける。

```shell
=== 20260428T091200Z-fix-login-bug run started on trinity/20260428T091200Z-fix-login-bug (base=main) ===
2026-04-28T09:12:05Z generator finished on a1b2c3d
2026-04-28T09:14:30Z evaluator finished
=== 20260428T091200Z-fix-login-bug run ended: PASS at iter 1 ===
=== 20260429T153000Z-add-theme-toggle run started on trinity/20260429T153000Z-add-theme-toggle (base=feat/x) ===
2026-04-29T15:30:48Z generator finished on 9c25f62
```

エージェント間の通信には使わない（評価ロジックの入力にはしない）。コスト監査と振り返り専用である。

## 12. 拡張・縮退の指針

ハーネスの各部品は「モデル単独でできないこと」についての仮定を表している。モデルが進化するにつれて不要になった部品は積極的に削るべきである。

**縮退のシグナル**

- Planner の計画が連続して無修正で通り、Generator からの確認も発生しない → 小タスクでは Planner を抜き、Generator が直接ユーザー要件から動かす
- Evaluator がイテレーション 1 で 90% 以上 PASS を返す → 評価軸が緩いか、Evaluator のコストが見合わない
- イテレーション 2 以降で判定が変わらない → `MAX_ITER` の既定値を下げる

**拡張の判断**

4つ目のエージェント（Planner の前に Researcher、Evaluator の後に Refiner）を足すのは、欠けている能力がボトルネックだと示す証拠が手に入ってからにする。先回りで足すべきものではない。

## 13. 参考資料

- Anthropic「Harness design for long-running apps」 https://www.anthropic.com/engineering/harness-design-long-running-apps
- Qiita「@nogataka 氏の解説記事」 https://qiita.com/nogataka/items/efe8eb9df612d2211221

---
description: "Planner → Generator → Evaluator のハーネスパイプラインを実行する。最終 PASS 後は push と PR 作成（または既存 PR への追加 push）を行い、ユーザー承認のもとでマージとクリーンアップまでを完結させる。使用例 `/trinity:run <要件>` または `/trinity:run --max-iter=5 <要件>` または `/trinity:run --resume=<RUN_DIR>`。"
argument-hint: "[--max-iter=N] [--resume=<RUN_DIR>] <1〜4文の要件>"
---

# /trinity:run — 3エージェント・ハーネスパイプライン

Planner が要件を計画に展開し、Generator が隔離された worktree で実装してコミットし、Evaluator が独立に判定する。PASS になるか `max_iter` に到達するまで繰り返す。PASS 後、worktree のブランチを push して PR を作成し、ユーザー承認のもとでマージとクリーンアップまでを行う。新規か既存 PR 継続かは実行手順 1 で自動判断する。

## 使うスキル

- `git-worktree` — 要件由来のスラッグを渡して隔離 worktree を作成する。新規経路はスラッグのみ渡し `origin/<デフォルトブランチ>` ベースの新規ブランチが切られる。既存 PR 継続経路はスラッグと `PR_NUMBER` を渡し PR の head ブランチが checkout される。`TS` / `SLUG` / `BRANCH` / `RUN_DIR` / `WORKTREE_DIR` / `BASE_BRANCH` はスキルが返す
- `git-pull-request` — PASS 後の push と PR 確定を一連フローで実行する。新規 PR は PR タイトルと PR 本文を渡して作成、既存 PR 継続は `PR_NUMBER` を渡して追加 push のみ（新規 PR 作成なし）。`PR_NUMBER` / `PR_URL` を返す
- `git-merge` — マージ可否確認の `AskUserQuestion` から、承認時のマージ・後始末、否認時の改善項目ヒアリングまでを内蔵する。呼び出し側から渡すのは PR URL のみ。新規 PR でも継続 PR でも同一フローで動く

## 引数

生の引数は `$ARGUMENTS` で受け取る。次の手順で解釈する（順序非依存）。

- `--max-iter=N`（N は正の整数）が含まれていれば `MAX_ITER = N`、含まれなければ `MAX_ITER = 15`（既定値）
- `--resume=<value>` が含まれていれば `RESUME_DIR` をその値から解決する（後述）。含まれなければ通常起動
- `MAX_ITER` は 0 以下なら停止して報告する
- 残りのトークンを「要件」として扱う。`--resume` を含まない場合、要件が空ならユーザーに 1〜4 文の要件を求めて停止する
- `--resume` がある場合に要件文も与えられたときは、`RESUME_DIR/plan.md` が存在すれば要件文を無視して既存 plan.md から要件を復元する。`plan.md` が存在しなければ通常起動と同じく要件文を Planner に渡す

### `RESUME_DIR` の解決

`--resume=<value>` の値から既存 RUN_DIR の絶対パスを解決する。

- `<value>` が `/` を含み絶対パスとして既存ディレクトリであればそのまま `RESUME_DIR` に使う
- 絶対パスでなければ `<repo-root>/.trinity/<value>` を試し、存在すればそれを使う
- いずれでも到達できなければ停止し、試したパスを両方ユーザーに報告する

### resume 時の事前検査

`RESUME_DIR` を解決したら次の検査を順に行う。

1. `${RESUME_DIR}/worktree/` が存在し、git worktree として登録されていること（`git worktree list --porcelain` の出力に `${RESUME_DIR}/worktree` が含まれること）。登録されていなければ停止して報告する
2. `${RESUME_DIR}/worktree` の working tree が clean であること（`git -C "${RESUME_DIR}/worktree" status --porcelain` の出力が空であること）。dirty なら停止し、ユーザーに状況確認を促す
3. 呼び出し元 cwd の clean 判定は既存 `hooks/hooks.json` の `UserPromptSubmit` プリフライトに委ねる。Orchestrator 側では `${RESUME_DIR}/worktree` の dirty 検査のみ行う

検査を通過したら以降の変数を再構成する。

- `RUN_DIR = RESUME_DIR`
- `WORKTREE_DIR = ${RESUME_DIR}/worktree`
- `BRANCH` = `git -C "$WORKTREE_DIR" rev-parse --abbrev-ref HEAD`（worktree が指すブランチをそのまま使う）
- `TS` と `SLUG` は `RUN_DIR` のディレクトリ名（`<TS>-<SLUG>` 形式）から取り出す

### 再開ポイントの決定

resume 時の再開ポイントは `${RUN_DIR}/plan.md` と `${RUN_DIR}/eval-*.md` の有無で決まる。

| `plan.md` | `eval-*.md` の最大 N | 直前 eval の判定 | 再開動作 |
| --- | --- | --- | --- |
| なし | — | — | 通常起動と同じ Planner から開始（イテレーション 1）|
| あり | 0 件 | — | Planner をスキップして Generator から再開（イテレーション 1）|
| あり | N >= 1 | `PASS` | ループに入らず最終化フェーズ（実行手順 4）に直行する |
| あり | N >= 1 | `NEEDS_REVISION` または `FAIL` | n = N + 1 から通常ループ（Planner → Generator → Evaluator）に入る。`n > MAX_ITER` のときは停止し、最新 `eval-N.md` パスと判定をユーザーに報告する |

`eval-N.md` の判定は、ファイル末尾近くに最初に出現する `PASS` / `NEEDS_REVISION` / `FAIL` の文字列を拾う。判定が読み取れない場合は停止し、ユーザーに当該 `eval-N.md` を確認するよう促す。

### resume 時にスキップする操作

- `git-worktree` スキルの呼び出し（新規 RUN_DIR / worktree / ブランチを作らない）
- `trinity.log` への「`run started`」行の追記（代わりに後述の「再開行」を追記する）

## プリフライト（hook 担当）

`UserPromptSubmit` hook が `/trinity:run` を検出したとき次を強制する。あなたはこれを再実装しない。

- カレントが git リポジトリであること
- ワーキングツリーが clean であること（汚れていれば prompt がブロックされる）
- 現在のブランチを stderr に表示する

起動した時点で「現在のブランチが clean なベースライン」であることが保証されている。

## ハーネス規範（全フェーズで守る不変ルール）

### 直列で呼ぶ

サブエージェントは並列ではなく直列に呼び出す。各段は前段の成果ファイルに依存し、並列化すると存在しない SHA を渡してしまう。チャンクも直列。

### 段と段のあいだでコードに触らない

オーケストレーターが `${WORKTREE_DIR}` 内のコードを `Read` / `Edit` / `Bash` で参照・編集してはいけない。許可されるのは下記のみ:

- `${RUN_DIR}` 配下のファイル名一覧の確認（読まない、開かない）
- `.trinity/trinity.log` への開始行・終了行の追記
- `git -C "$WORKTREE_DIR" rev-parse` などの非破壊 git メタ問い合わせ
- `git -C "$WORKTREE_DIR" push`（最終化のみ）

### エージェント出力を要約しない

Generator の検証レポートを圧縮して Evaluator に渡してはいけない。Generator が書いたレポート本文をそのまま渡す。各段への入力:

- Planner: 要件文 / `Iteration` / `RUN_DIR` / `WORKTREE_DIR` / 必要なら `eval-<n-1>.md` の存在告知
- Generator（チャンクごと）: `RUN_DIR` / `WORKTREE_DIR` / `BRANCH` / `Iteration` / `ChunkIndex` / `ChunkTotal` / `ChunkFiles`
- Evaluator: `RUN_DIR` / `WORKTREE_DIR` / `Iteration` / 最終コミット SHA / `ChunkTotal` / 最終チャンクレポートパス（`${RUN_DIR}/gen-<n>-chunk-<ChunkTotal>.md`）

### 最終出力以外を喋らない

最終出力フォーマット 1 ブロック + 2〜3 文の要約だけを返す。次の場合のみ例外的に出力して停止またはユーザー入力を待つ: Planner の `AskUserQuestion` / Generator がコミット未作成 / push 恒久失敗 / `git-merge` のマージ可否確認 / PASS 後の起票候補ヒアリング（4d / 4e）。

## 実行手順

1. **準備**: `--resume` の有無で次の 2 経路に分岐する。

   **resume 起動（`--resume=<value>` あり）**: `git-worktree` スキルは呼ばない。`## 引数` の「`RESUME_DIR` の解決」「resume 時の事前検査」「再開ポイントの決定」の手順で変数を確定する。worktree clean 検査を通過した直後に `.trinity/trinity.log` に再開行を追記する。

   ```shell
   # resume 時の trinity.log 再開行（最終化直行のときは "(finalize)" を付けてよい）
   printf '=== %s run resumed from iter %d ===\n' "${TS}-${SLUG}" "$n" >> .trinity/trinity.log
   ```

   `<n>` は再開ポイント決定で確定した次のイテレーション番号。直前 PASS で最終化に直行する場合は `from iter <N> (finalize)` の形にしてよい。

   **通常起動（`--resume` なし）**: 「現在のリポジトリ状態から既存作業を自動判断する」（下記参照）ことで `PR_NUMBER` を決め、`git-worktree` スキルを呼んで隔離 worktree を作成する。

   要件文または継続対象の PR タイトルから kebab-case のスラッグ（2〜5 語）を生成する。リポジトリパス・ベースブランチ・ログファイルパスはスキル内で推測する。

   - `SLUG` = `PR_NUMBER` 未設定時は要件文から派生（例: 「ユーザー設定ページにテーマトグルを追加する」→ `add-theme-toggle`）。`PR_NUMBER` 確定時は `gh pr view <PR_NUMBER>` で取得した PR タイトルから派生させた kebab-case スラッグ

   スキルから次の値を受け取り、以降のすべてのフェーズで使う。

   - `TS` — タイムスタンプ
   - `SLUG` — 確定した slug（衝突時は `-2` `-3` を付けて一意化された値）
   - `BRANCH` — 新規経路では `trinity/<TS>-<SLUG>` 形式。既存 PR 継続経路では PR の head ブランチ名
   - `RUN_DIR` — run ディレクトリの絶対パス
   - `WORKTREE_DIR` — worktree の絶対パス
   - `BASE_BRANCH` — base ブランチ名
   - `PR_NUMBER` / `PR_URL` — 既存 PR 継続の場合のみ返る

   ### 現在のリポジトリ状態から既存作業を自動判断する

   **判定の入力**（ユーザーの cwd を見る）:

   ```shell
   CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
   DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
   # gh 不在時のフォールバック
   if [ -z "$DEFAULT_BRANCH" ]; then
     DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
   fi
   MATCHED_PRS=$(gh pr list --head "$CURRENT_BRANCH" --state open --json number,headRefName,url,state)
   MATCHED_PR_COUNT=$(echo "$MATCHED_PRS" | jq 'length')
   ```

   **判定の決定木**（上から順に評価し、最初にマッチしたものを採用する）:

   | # | 条件 | 結果 |
   | --- | --- | --- |
   | 1 | `CURRENT_BRANCH == DEFAULT_BRANCH` | 新規ブランチで始める。`PR_NUMBER` は設定しない |
   | 2 | `CURRENT_BRANCH` が `trinity/` プレフィックスを持たない | 新規ブランチで始める。Trinity 起源でないブランチ上の実行は安全のため新規扱いとする |
   | 3 | `CURRENT_BRANCH` が `trinity/` プレフィックスを持ち、`MATCHED_PR_COUNT == 0` | 新規ブランチで始める。trinity ブランチだが open PR が未作成 |
   | 4 | `CURRENT_BRANCH` が `trinity/` プレフィックスを持ち、`MATCHED_PR_COUNT == 1` | 既存 PR を継続する。`PR_NUMBER = MATCHED_PRS[0].number` に確定し、`git-worktree` スキルに渡す |
   | 5 | `CURRENT_BRANCH` が `trinity/` プレフィックスを持ち、`MATCHED_PR_COUNT >= 2` | 停止。曖昧ケース。全 PR 番号と URL をユーザーに表示し「同一ブランチに複数の open PR が紐付いています。意図する PR を確認してから再実行してください」と案内する |

   決定木 #4 で `MATCHED_PRS[0].state` が `OPEN` 以外であれば停止して報告する（理論上ありえないが念のため）。

   **`git-worktree` スキルの呼び出し**: `PR_NUMBER` 未設定時はスラッグのみ渡して新規ブランチを切る。`PR_NUMBER` 確定時はスラッグと `PR_NUMBER` を渡して PR の head ブランチを checkout する（新規ブランチは作らない）。

2. **ループ**: `n = 1 .. MAX_ITER` で次を順に呼ぶ（並列にしない）。resume の場合は「再開ポイントの決定」で確定した `n` から始める。直前 eval が `PASS` なら実行手順 4 に直行する。

   - **Planner**: `trinity:planner` サブエージェントを起動。要件（原文ママ）、`Iteration: <n>`、`RUN_DIR`、`WORKTREE_DIR`、`n > 1` なら直前 `eval-<n-1>.md` の存在告知を渡す。`${RUN_DIR}/plan.md` を書く（再計画時は上書き）。`AskUserQuestion` を投げた場合はそのまま見せて停止する。resume で「`plan.md` あり・`eval-*.md` なし」の場合は Planner をスキップして Generator から始める（既存の `plan.md` をそのまま使う）。
   - **Generator（チャンク反復）**: `${RUN_DIR}/plan.md` の `## 影響範囲` をパースしてチャンク総数 `M` とチャンク列を決定し、`i = 1..M` の順で `trinity:generator` サブエージェントを直列に起動する（詳細は後述「Generator チャンク分割の契約」）。チャンク `i` のレポートは `${RUN_DIR}/gen-<n>-chunk-<i>.md` に書かれる。Generator が「検証失敗 → 自力修正不能 → コミット未作成」となったら後続チャンクを起動せずループを停止し、失敗チャンク番号 `i/M` ・レポートパス・失敗内容をユーザーに報告する。存在しないコミットを Evaluator に渡してはいけない。
   - **Evaluator**: 全チャンク成功時のみ起動する。`LAST_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD)` でイテレーション内最終コミット SHA を取得し、`trinity:evaluator` に `RUN_DIR`、`WORKTREE_DIR`、`Iteration`、`LAST_SHA`、`ChunkTotal: <M>`、最終チャンクレポートパス（`${RUN_DIR}/gen-<n>-chunk-<M>.md`）を渡す。`${RUN_DIR}/eval-<n>.md` と判定（`PASS` / `NEEDS_REVISION` / `FAIL`）を受け取る。

3. **判定に応じた分岐**:

   | 判定 | 残りイテレーション | 動作 |
   | --- | --- | --- |
   | `PASS` | — | ループ脱出。以降の最終化フェーズに進む |
   | `NEEDS_REVISION` | `n < MAX_ITER` | 続行。Planner は次周回で `plan.md` を**上書き** |
   | `FAIL` | `n < MAX_ITER` | 続行。Planner はより踏み込んだ再計画を行う |
   | `NEEDS_REVISION` または `FAIL` | `n == MAX_ITER` | 最終化をスキップ。最新の評価レポートのパスと未解決の指摘を表示して停止 |

   `FAIL` を「だいたい OK」と解釈してループを抜けない。`MAX_ITER` を黙って延長しない。

4. **PASS のとき**: 実行手順 1 で確定した `PR_NUMBER` の有無に応じて次を順に実行する。

   **a. PR タイトルと PR 本文を組み立てる（`PR_NUMBER` 未設定時のみ）**

   PR タイトルは `plan.md` 先頭 H1（70 文字超なら切り詰め）。PR 本文は `.trinity/` が gitignore されレビュアーから見えないため、計画と判定の核心を次のテンプレートに埋め込む:

   ```
   ## 概要
   <plan.md の "目的" セクション本文をそのまま貼る>

   ## 受け入れ基準
   <plan.md の "受け入れ基準" セクションを箇条書きでそのまま貼る>

   ## Trinity 実行サマリ
   - Run: <RUN_DIR を repo ルートからの相対パスで>
   - Iterations: <n>/<MAX_ITER>
   - Final verdict: PASS
   - Final commit: <短縮SHA>

   ## 判定根拠（最終 Evaluator レポートからの抜粋）
   <eval-<n>.md の "判定" セクションをそのまま貼る>
   ```

   **b. `git-pull-request` を呼ぶ**: `PR_NUMBER` 未設定時は `PR_TITLE` と `PR_BODY` を渡して新規 PR を作成（`PR_NUMBER` / `PR_URL` を受け取る）。`PR_NUMBER` 確定時は `PR_NUMBER` のみを渡して追加 push のみ実行（`PR_URL` を受け取る）。worktree パス・ブランチ名・ベースブランチ・リモート情報はスキル内で推測する。

   **c. `git-merge` を呼ぶ**

   PR URL のみ渡す（`PR_URL` = 上で取得した値）。マージ可否確認の `AskUserQuestion`、承認時のマージ・後始末（リモート/ローカルブランチ削除・worktree 削除・run ディレクトリ削除）、否認時の改善項目ヒアリングまでスキル内で完結する。スキルから次の値を受け取る。

   - `MERGE_RESULT` — `merged` / `closed` / `needs-revision-with-followup-requirements` のいずれか
   - `FOLLOWUP_REQUIREMENT` — `needs-revision-with-followup-requirements` のときだけ返る、次回実行用の要件文

   `MERGE_RESULT` が `needs-revision-with-followup-requirements` のとき `FOLLOWUP_REQUIREMENT` を `Followup: <内容>` として最終出力に反映する。

   **d. PASS 後の起票候補ヒアリング（ユーザープロジェクト向け）**

   PR 確定（4b）が成功した経路では 4c の結果にかかわらず実施する。詳細は後述「post-run-issue-suggestions」に従う。起票結果は `Issues:` セクションに反映する。

   **e. PASS 後の trinity プラグイン自身バグ・要望ヒアリング**

   ステップ 4d の直後・6/7 の直前に実施する。詳細は後述「post-run-trinity-self-issue-suggestions」に従う。起票先リポジトリは `yjn279/trinity` でハードコード。起票結果は `Issues:` セクションに反映する。

5. **PASS でない / `MAX_ITER` 到達**: 最終化をスキップ。最新の評価レポートのパスと未解決の指摘を表示して停止。push・PR 作成・マージ確認・クリーンアップ・起票候補ヒアリングを行わない。

6. **ログ**: ループ脱出時・`MAX_ITER` 到達時に `.trinity/trinity.log` に終了行を追記する。

   ```shell
   # PASS で抜けたとき
   printf '=== %s run ended: PASS at iter %d ===\n' "${TS}-${SLUG}" "$n" >> .trinity/trinity.log

   # MAX_ITER で抜けたとき
   printf '=== %s run ended: %s at iter %d/%d ===\n' "${TS}-${SLUG}" "${VERDICT}" "$n" "$MAX_ITER" >> .trinity/trinity.log
   ```

7. **最終出力**: 次のフォーマットでちょうど印字し、2〜3 文の要約を添える。`Task:` は常に出す。各キーの出力条件は inline コメントを参照。`PR:` 行は `#<N> <URL>` フォーマット。要件文は連続空白を半角スペース 1 個に畳み、200 文字超なら末尾を `…`（U+2026）で切る。

   ```
   Trinity result: <PASS | NEEDS_REVISION at iter <n> | FAIL at iter <n>>
   Task:    <要件文を1行に正規化したもの（200文字超なら末尾を…で切る）>
   RunDir:  <RUN_DIR>
   Branch:  <BRANCH> (base: <BASE_BRANCH>)
   Plan:    <RUN_DIR>/plan.md
   Commit:  <最後のコミットSHA>
   Eval:    <RUN_DIR>/eval-<n>.md
   Iters:   <n>/<MAX_ITER>
   PR:      #<PR_NUMBER> <PR_URL>                                   # PASS のときのみ
   Merge:   <merged | closed | needs-revision | failed: <理由>>      # PASS のときのみ
   Cleanup: <done | skipped | partial: <残っている操作>>              # PASS のときのみ
   Followup: <FOLLOWUP_REQUIREMENT>                                  # needs-revision のときのみ
   Issues:                                                 # PASS かつ起票が1件以上発生したときのみ
     <ユーザープロジェクト向け issue URL 1>     # post-run-issue-suggestions の起票結果
     <ユーザープロジェクト向け issue URL 2>
     ...
     <trinity プラグイン向け issue URL 1>     # post-run-trinity-self-issue-suggestions の起票結果
     <trinity プラグイン向け issue URL 2>
     ...
   ```

`/trinity:run` の起動自体がパイプライン全体への明示的な許可（push・PR 作成・起票候補ヒアリングを含む）だが、マージとクリーンアップだけは `git-merge` スキルが呼ぶ `AskUserQuestion` で改めてユーザーの承認を取る。

## Generator チャンク分割の契約

Generator フェーズはチャンク分割で `trinity:generator` サブエージェントを順次起動する。各チャンクが独立な Claude CLI ターン予算を持つことで、出力上限超過を回避する。

### チャンク列の決定（plan.md のパース）

`${RUN_DIR}/plan.md` の `## 影響範囲` セクションを次の手順で決定的にパースしチャンク列を組み立てる。

1. `## 影響範囲` セクション配下に `### チャンク N: ...`（N は 1 以上の整数）の H3 サブセクションが 1 個以上あれば各サブセクションを 1 チャンクとして扱う。ChunkFiles はそのサブセクション内に箇条書き・コードフェンス・本文 `path` 形式で列挙されたファイルパスから取り出す。
2. `### チャンク N: ...` サブセクションが存在しなければ、`## 影響範囲` テーブル全体を 1 チャンクとして扱う。テーブルの 1 列目（`ファイル / モジュール`）から `path:line` の `path` 部分を抽出してファイル群とする（列順は `ファイル / モジュール | 変更種別 | 理由` を前提とする）。
3. パース結果が空（ファイル群が 0 件）の場合は停止し、`${RUN_DIR}/plan.md` の `## 影響範囲` を確認するようユーザーに報告する。

```shell
# チャンク総数の計算（例: bash/awk による H3 カウント）
CHUNK_TOTAL=$(awk '/^## 影響範囲/{in_sec=1} in_sec && /^### チャンク [0-9]+:/{count++} /^## [^#]/{if(in_sec && !/^## 影響範囲/)in_sec=0} END{print (count>0?count:1)}' "${RUN_DIR}/plan.md")
```

> **Planner への注記**: Planner は `## 影響範囲` 配下に `### チャンク N: <タイトル>` サブセクションを任意で書くことで、Orchestrator のチャンク分割動作を制御できる。`agents/planner.md` 本体は変更しない。

### チャンクごとの順次起動

チャンク総数 `M` を決定したら、`i = 1..M` の順で `trinity:generator` サブエージェントを**順次**起動する（並列起動はしない）。各チャンク `i` の起動入力:

- `RUN_DIR: <絶対パス>`
- `WORKTREE_DIR: <絶対パス>`
- `BRANCH: <ブランチ名>`
- `Iteration: <n>`
- `ChunkIndex: <i>`
- `ChunkTotal: <M>`
- `ChunkFiles: <i 番目のチャンクのファイル列、カンマ区切り>`

各チャンクは `${RUN_DIR}/gen-<n>-chunk-<i>.md` にレポートを書き、その絶対パスを返す。Orchestrator はそのパスを保持する。

### 停止条件

あるチャンク `i` で Generator が「検証失敗 → 自力修正不能 → コミット未作成」となった場合、後続チャンクを起動せずループを停止し、失敗チャンク番号 `i` / `M`・レポートパス（`${RUN_DIR}/gen-<n>-chunk-<i>.md`）・失敗内容をユーザーに報告する。存在しないコミットを Evaluator に渡してはいけない。

### Evaluator への引き渡し

全チャンク成功時、次のコマンドでイテレーション内最終コミット SHA を取得し、SHA と `ChunkTotal: <M>` を Evaluator に渡す。

```shell
LAST_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
```

Evaluator 側で `ChunkTotal > 1` のときに中間コミットを遡る契約のため、各チャンクの中間コミット SHA を個別に渡す必要はない。

## PASS後の起票候補ヒアリング（post-run-issue-suggestions）

### 共通構造（両段共通）

両段（実行手順 4d / 4e）は PASS かつ PR 確定が成功した経路でのみ実施する（`NEEDS_REVISION` / `FAIL` 到達時はスキップ）。差分は候補抽出元・起票先 repo・スキップファイル名・`Issues:` 内の並び位置のみ（各段「差分」節参照）。

**候補の整理**: 各候補をタイトル候補（issue タイトル 1 文）と本文候補（背景・期待動作・関連ファイルパス等）の 2 要素で整理する。16 件超は上位 16 件に絞りスキップファイルにメモする。

**ユーザーへの提示（AskUserQuestion）**: 候補が 1 件以上ある場合のみ `AskUserQuestion`（`multiSelect=true`）を **1コール** 呼ぶ。

| 候補数 | 問数 |
| --- | --- |
| 1〜4 | 1問 |
| 5〜8 | 2問 |
| 9〜12 | 3問 |
| 13〜16 | 4問 |

1 問あたり最大 4 オプション、1 コールあたり最大 4 問。ラベル＝タイトル候補、description＝本文候補の短い要約。「Other」は自動付与。

**同意 = 即起票**: 選択された候補は `gh issue create` を 1 件ずつ連続実行する。

```shell
gh issue create --repo <owner/repo> --title "<title>" --body "<body>"
```

**拒否候補の保存**: 選択されなかった候補はスキップファイルに Markdown 形式で書き出す（タイトル候補 / 本文候補 / 抽出元）。

**起票結果**: 1 件以上起票したとき `Issues:` セクションに URL を列挙する。候補 0 件なら `AskUserQuestion` も起票も行わない。

### 候補の抽出（post-run-issue-suggestions 固有）

次の 3 系統を抽出元とする。本段はオーケストレーターの責務であり、サブエージェント定義（`agents/*.md`）は変更しない。

1. **最新 `${RUN_DIR}/eval-<n>.md` のリスク・懸念 / 次イテレーション / 持ち越し指摘相当のセクション**
2. **同 run の Generator 検証レポート（`${RUN_DIR}/gen-<n>-chunk-*.md`）の NOTES** — 計画外の逸脱・妥協ポイント
3. **PR 本文の「明示的にスコープ外」セクションの項目**

### 差分（post-run-issue-suggestions 固有）

- **起票先 repo**: `git -C "$WORKTREE_DIR" remote get-url origin` の出力から `<owner/repo>` を動的に抽出して使う
- **スキップファイル**: `${RUN_DIR}/skipped-suggestions.md`
- **`Issues:` 内の位置**: 「ユーザープロジェクト向け」ブロック（先）

## PASS後 trinity プラグイン自身バグ・要望ヒアリング（post-run-trinity-self-issue-suggestions）

実行手順 4e（4d の直後・6/7 の直前）。前段が存在しなくても単体で成立する。共通構造は前段「共通構造」節を参照。

### 候補の抽出（post-run-trinity-self-issue-suggestions 固有）

本 run 中の観察・`${RUN_DIR}/eval-<n>.md`・Generator NOTES の中から **trinity プラグイン本体（`yjn279/trinity`）の挙動に起因する** ものを拾う。ユーザーのプロジェクトコードに起因するものは前段（4d）に任せる。

例: skill 指示が曖昧でエージェントが解釈を迷った / hook が期待どおり起動しなかった / `agents/*.md` の指示が冗長で解釈が割れた / `commands/run.md` の既存ステップに矛盾があった。

### 差分（post-run-trinity-self-issue-suggestions 固有）

- **起票先 repo**: `yjn279/trinity` でハードコード

  ```shell
  gh issue create --repo yjn279/trinity --title "<title>" --body "<body>"
  ```

- **スキップファイル**: `${RUN_DIR}/skipped-trinity-self-suggestions.md`
- **`Issues:` 内の位置**: 「trinity プラグイン向け」ブロック（後）

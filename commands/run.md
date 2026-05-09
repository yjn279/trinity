---
description: "Planner → Generator → Evaluator のハーネスパイプラインを実行する。最終 PASS 後は push と PR 作成を行い、ユーザー承認のもとでマージとクリーンアップまでを完結させる。使用例 `/trinity:run <要件>` または `/trinity:run --max-iter=5 <要件>` または `/trinity:run --resume=<RUN_DIR>`。"
argument-hint: "[--max-iter=N] [--resume=<RUN_DIR>] <1〜4文の要件>"
---

# /trinity:run — 3エージェント・ハーネスパイプライン

ハーネスを取り回すスラッシュコマンドである。Planner が要件を計画に展開し、Generator が隔離された worktree で実装してコミットし、Evaluator が独立に判定する。判定が PASS になるか、`max_iter` に到達するまで繰り返す。最終 PASS 後、worktree のブランチを push して PR を作成し、ユーザー承認のもとでマージとクリーンアップまでを行う。

## 使うスキル

このコマンドの実行手順は次の 3 スキルに分割されている。各フェーズで該当スキルを参照し、その手順に従う。スキル本文を要約せず、書かれている規範をそのまま守ること。

- `git-worktree` — 起動直後、要件由来のスラッグだけ渡して隔離 worktree を作成する。TS / SLUG / BRANCH / RUN_DIR / WORKTREE_DIR / BASE_BRANCH はスキルが返す
- `git-pull-request` — PASS 後の origin への push と PR 作成を一連フローで実行する。呼び出し側から渡すのは PR タイトルと PR 本文のみで、`PR_NUMBER` / `PR_URL` を返す
- `git-merge` — マージ可否確認の `AskUserQuestion` から、承認時のマージ・後始末、否認時の改善項目ヒアリングまでを内蔵する。呼び出し側から渡すのは PR URL のみ

## 引数

生の引数は `$ARGUMENTS` で受け取る。次の手順で解釈する。順序非依存で、両フラグが同時に与えられても処理する。

- `--max-iter=N`（N は正の整数）が含まれていれば `MAX_ITER = N`、含まれなければ `MAX_ITER = 15`（既定値）
- `--resume=<value>` が含まれていれば `RESUME_DIR` をその値から解決する（後述）。含まれなければ通常起動
- `MAX_ITER` は 1 未満を受け付けない。0 以下なら停止して報告する
- `--resume` を含まない場合、残りのトークンを「要件」として扱う。要件が空ならユーザーに 1〜4 文の要件を求めて停止する
- `--resume` がある場合、要件文を同時に指定してはいけない。要件文と `--resume` が両方与えられたら停止して報告する（resume 時は要件を既存 `plan.md` から復元するため、追加要件は誤投入リスクが大きい）

### `RESUME_DIR` の解決

`--resume=<value>` の値から既存 RUN_DIR の絶対パスを次の手順で解決する。

- `<value>` が `/` を含み、絶対パスとして既存ディレクトリであればそのまま `RESUME_DIR` に使う
- 絶対パスでなければ `<repo-root>/.trinity/<value>` を試し、存在すればそれを使う
- いずれの形でも既存ディレクトリに到達できなければ停止し、試したパスを両方ユーザーに報告する

### resume 時の事前検査

`RESUME_DIR` を解決したら次の検査を順に行う。

1. `${RESUME_DIR}/worktree/` が存在し、git worktree として登録されていること（`git worktree list --porcelain` の出力に `${RESUME_DIR}/worktree` が含まれること）。登録されていなければ停止して報告する
2. `${RESUME_DIR}/worktree` の working tree が clean であること（`git -C "${RESUME_DIR}/worktree" status --porcelain` の出力が空であること）。dirty なら停止し、ユーザーに状況確認を促す
3. 呼び出し元 cwd の clean 判定は既存 `hooks/hooks.json` の `UserPromptSubmit` プリフライトに委ねる。Orchestrator 側では `${RESUME_DIR}/worktree` の dirty 検査のみ行う

上記検査を通過したら以降の変数を再構成する。

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
| あり | N >= 1 | `NEEDS_REVISION` または `FAIL` | `n = N + 1` から通常ループ（Planner → Generator → Evaluator）に入る。`n > MAX_ITER` のときは停止し、最新 `eval-N.md` パスと判定をユーザーに報告する |

`eval-N.md` の判定は、ファイル末尾近くに最初に出現する `PASS` / `NEEDS_REVISION` / `FAIL` の文字列を拾う（Evaluator の出力契約に従う）。判定が読み取れない場合は停止し、ユーザーに当該 `eval-N.md` を確認するよう促す。

### resume 時にスキップする操作

resume 経路では次の操作を行わない。

- `git-worktree` スキルの呼び出し（新規 RUN_DIR / worktree / ブランチを作らない）
- `trinity.log` への「`run started`」行の追記（代わりに後述の「再開行」を追記する）

## プリフライト（hook 担当）

`UserPromptSubmit` hook が `/trinity:run` を検出したとき次を強制する。あなたはこれを再実装しない。

- カレントが git リポジトリであること
- ワーキングツリーが clean であること（汚れていれば prompt がブロックされる）
- 現在のブランチを stderr に表示する

このため、本コマンドが起動した時点で「現在のブランチが clean なベースライン」であることが保証されている。

## ハーネス規範（全フェーズで守る不変ルール）

これらのルールは全フェーズで例外なく適用する。

### 直列で呼ぶ

サブエージェントは並列ではなく直列に呼び出す。各段は前段の成果ファイル（`plan.md` / コミット / `eval-<n>.md`）に依存している。Evaluator はコミット SHA を入力に取るので、Generator が終わってからしか起動できない。並列化すると存在しない SHA を渡してしまう。Generator の同一イテレーション内チャンクも同様に直列で起動する（並列起動はしない）。

### 段と段のあいだでコードに触らない

オーケストレーターが `Read` `Edit` `Bash` で `${WORKTREE_DIR}` 内のコードを読んだり編集したりしてはいけない。例外なく禁止する。触ってよいのは次だけである。

- `${RUN_DIR}` 配下のファイル名一覧の確認（読まない、開かない）
- `.trinity/trinity.log` への開始行・終了行の追記
- `git -C "$WORKTREE_DIR" rev-parse` などの非破壊・非読取の git メタ問い合わせ
- `git -C "$WORKTREE_DIR" push`（最終化のみ）

### エージェント出力を要約しない

Generator の検証レポートを圧縮して Evaluator に渡してはいけない。Generator が書いたレポート本文をそのまま渡す。各段への入力は次のとおり最小化する。

- Planner: 要件文、`Iteration`、`RUN_DIR`、`WORKTREE_DIR`、必要なら `eval-<n-1>.md` の存在告知
- Generator（チャンクごと）: `RUN_DIR`、`WORKTREE_DIR`、`BRANCH`、`Iteration`、`ChunkIndex`、`ChunkTotal`、`ChunkFiles`
- Evaluator: `RUN_DIR`、`WORKTREE_DIR`、`Iteration`、イテレーション内最終コミット SHA、`ChunkTotal`、最終チャンクの検証レポートパス（`${RUN_DIR}/gen-<n>-chunk-<ChunkTotal>.md`）

### 最終出力以外を喋らない

ループ中、各段の途中報告をユーザーに垂れ流さない。最終出力フォーマット 1 ブロック + 2〜3 文の要約だけを返す。例外は次の場合だけである。

- Planner が `AskUserQuestion` で確認を投げた → そのまま見せて停止
- Generator がコミットを作れずに停止 → 失敗内容を見せて停止
- push に恒久失敗が起きた → 原文を見せて停止（`git-pull-request` 参照）
- `git-merge` スキル内のマージ可否確認 `AskUserQuestion`（実行手順 4c） → ユーザー回答を待つ
- PASS 後の起票候補ヒアリング `AskUserQuestion`（実行手順 4d / 4e） → ユーザー回答を待つ

## 実行手順

1. **準備**: `--resume` の有無で分岐する。

   **通常起動（`--resume` なし）**: `git-worktree` スキルを呼んで隔離 worktree を作成する。

   呼び出し側で要件文から kebab-case のスラッグ（2〜5 語）を生成し、それだけをスキルに渡す。リポジトリパス・ベースブランチ・ログファイルパスはスキル内で推測する。

   - `SLUG` = 要件文から派生した kebab-case のスラッグ（例: 「ユーザー設定ページにテーマトグルを追加する」→ `add-theme-toggle`）

   スキルから次の値を受け取り、以降のすべてのフェーズで使う。

   - `TS` — タイムスタンプ
   - `SLUG` — 確定した slug（衝突時は `-2` `-3` を付けて一意化された値）
   - `BRANCH` — ブランチ名（`trinity/<TS>-<SLUG>` 形式）
   - `RUN_DIR` — run ディレクトリの絶対パス
   - `WORKTREE_DIR` — worktree の絶対パス
   - `BASE_BRANCH` — スキルが推測した base ブランチ名

   **resume 起動（`--resume=<value>` あり）**: `git-worktree` スキルは呼ばない。`## 引数` の「`RESUME_DIR` の解決」「resume 時の事前検査」「再開ポイントの決定」の手順で変数を確定する。worktree clean 検査を通過した直後に `.trinity/trinity.log` に再開行を追記する。

   ```shell
   # resume 時の trinity.log 再開行（最終化直行のときは "(finalize)" を付けてよい）
   printf '=== %s run resumed from iter %d ===\n' "${TS}-${SLUG}" "$n" >> .trinity/trinity.log
   ```

   `<n>` は再開ポイント決定で確定した「次に実行するイテレーション番号」。直前 PASS で最終化に直行する場合は、最後に実行されたイテレーション番号 `N` を使い `from iter <N> (finalize)` の形にしてよい。

2. **ループ**: `n = 1 .. MAX_ITER` で次を順に呼ぶ。並列にしない。resume の場合は「再開ポイントの決定」で確定した `n` から始める。直前 eval の判定が `PASS` だった場合はループに入らず実行手順 4 に直行する。

   - **Planner**: `trinity:planner` サブエージェントを起動。要件（原文ママ）、`Iteration: <n>`、`RUN_DIR`、`WORKTREE_DIR`、`n > 1` なら直前 `eval-<n-1>.md` の存在告知を渡す。`${RUN_DIR}/plan.md` を書く（再計画時は上書き）。Planner が `AskUserQuestion` を投げた場合はそのまま見せて停止する。resume で「`plan.md` あり・`eval-*.md` なし」の場合は Planner をスキップして Generator から始める（イテレーション 1、既存の `plan.md` をそのまま使う）。
   - **Generator（チャンク反復）**: `${RUN_DIR}/plan.md` の `## 影響範囲` をパースしてチャンク総数 `M` とチャンク列を決定し、`i = 1..M` の順で `trinity:generator` サブエージェントを直列に起動する。詳細は後述「Generator チャンク分割の契約」に従う。チャンク `i` のレポートは `${RUN_DIR}/gen-<n>-chunk-<i>.md` に書かれる。あるチャンクで Generator が「検証失敗 → 自力修正不能 → コミット未作成」となったら、後続チャンクを起動せずループを停止し、失敗チャンク番号 `i/M` ・最後のレポートパス・失敗内容をユーザーに報告する。存在しないコミットを Evaluator に渡してはいけない。
   - **Evaluator**: 全チャンク成功時のみ起動する。`LAST_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD)` でイテレーション内最終コミット SHA を取得し、`trinity:evaluator` サブエージェントに `RUN_DIR`、`WORKTREE_DIR`、`Iteration`、`LAST_SHA`、`ChunkTotal: <M>`、最終チャンクのレポートパス（`${RUN_DIR}/gen-<n>-chunk-<M>.md`）を渡す。`${RUN_DIR}/eval-<n>.md` と判定（`PASS` / `NEEDS_REVISION` / `FAIL`）を受け取る。

3. **判定に応じた分岐**:

   | 判定 | 残りイテレーション | 動作 |
   | --- | --- | --- |
   | `PASS` | — | ループ脱出。以降の最終化フェーズに進む |
   | `NEEDS_REVISION` | `n < MAX_ITER` | 続行。Planner は次周回で `plan.md` を**上書き** |
   | `FAIL` | `n < MAX_ITER` | 続行。Planner はより踏み込んだ再計画を行う |
   | `NEEDS_REVISION` または `FAIL` | `n == MAX_ITER` | 最終化をスキップ。最新の評価レポートのパスと未解決の指摘を表示して停止 |

   `FAIL` を「だいたい OK」と解釈してループを抜けない。`MAX_ITER` を黙って延長しない。

4. **PASS のとき**: 次を順に実行する。

   **a. PR タイトルと PR 本文を組み立てる**

   PR タイトルは `${RUN_DIR}/plan.md` の先頭 H1 をそのまま使う。70 文字を超えるなら冒頭で切り詰める。

   PR 本文は次の形にする。`.trinity/` は gitignore されておりレビュアーから見えないため、計画と判定の核心は本文に埋め込む。

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

   **b. `git-pull-request` を呼ぶ**

   組み立てた PR タイトルと PR 本文だけをスキルに渡す。worktree パス・ブランチ名・ベースブランチ・リモート情報はスキル内で推測する。

   - `PR_TITLE` = 上で組み立てた PR タイトル
   - `PR_BODY` = 上で組み立てた PR 本文

   返ってきた `PR_NUMBER` / `PR_URL` を保持する。

   **c. `git-merge` を呼ぶ**

   PR URL だけをスキルに渡す。マージ可否確認の `AskUserQuestion`、承認時のマージ・後始末（リモート/ローカルブランチ削除、worktree 削除、run ディレクトリ削除）、否認時の改善項目ヒアリングまで、すべてスキル内で完結する。ブランチ名・worktree パス・run ディレクトリのパス・リポジトリパスはスキル内で推測する。

   - `PR_URL` = 上で取得した値

   スキルから次の値を受け取る。

   - `MERGE_RESULT` — `merged` / `closed` / `needs-revision-with-followup-requirements` のいずれか
   - `FOLLOWUP_REQUIREMENT` — `needs-revision-with-followup-requirements` のときだけ返る、次回実行用の要件文

   `MERGE_RESULT` が `needs-revision-with-followup-requirements` の場合は、`FOLLOWUP_REQUIREMENT` を `Followup: <内容>` として最終出力に反映する。

   **d. PASS 後の起票候補ヒアリング（ユーザープロジェクト向け）**

   PR 作成（4b）が成功した経路では、4c の結果（マージ・クローズ・needs-revision）にかかわらず本ステップを実施する。詳細は後述「PASS後の起票候補ヒアリング（post-run-issue-suggestions）」に従う。`AskUserQuestion` を 1 コール呼び（候補数に応じて 1〜4 問に分割）、選択された候補は即 `gh issue create` する。起票結果は最終出力（ステップ 7）の `Issues:` セクションに反映する。

   **e. PASS 後の trinity プラグイン自身バグ・要望ヒアリング**

   ステップ 4d の直後、ステップ 6/7 の直前に実施する。詳細は後述「PASS後 trinity プラグイン自身バグ・要望ヒアリング（post-run-trinity-self-issue-suggestions）」に従う。起票先リポジトリは `yjn279/trinity` でハードコード。起票結果は最終出力の `Issues:` セクションに反映する。

5. **PASS でない / `MAX_ITER` 到達**: 最終化をスキップし、最新の評価レポートのパスと未解決の指摘をユーザーに表示して停止。push も PR 作成もマージ確認もクリーンアップも起票候補ヒアリングも行わない。

6. **ログ**: ループ脱出時または `MAX_ITER` 到達時に `.trinity/trinity.log` に終了行を追記する。

   ```shell
   # PASS で抜けたとき
   printf '=== %s run ended: PASS at iter %d ===\n' "${TS}-${SLUG}" "$n" >> .trinity/trinity.log

   # MAX_ITER で抜けたとき
   printf '=== %s run ended: %s at iter %d/%d ===\n' "${TS}-${SLUG}" "${VERDICT}" "$n" "$MAX_ITER" >> .trinity/trinity.log
   ```

7. **最終出力**: 次のフォーマットでちょうど印字し、2〜3 文の要約を添える。最終化を実施した（PASS で抜けた）場合だけ `PR:` `Merge:` `Cleanup:` の 3 行を加える。`Issues:` セクションは PASS かつ起票が 1 件以上発生したときだけ加える。

   ```
   Trinity result: <PASS | NEEDS_REVISION at iter <n> | FAIL at iter <n>>
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

   `Issues:` セクションは「ユーザープロジェクト向け」（`post-run-issue-suggestions` 段の起票結果）と「trinity プラグイン向け」（`post-run-trinity-self-issue-suggestions` 段の起票結果）の 2 連続ブロックとして並列に出力する。各ブロックはそれぞれ 1 件以上起票されたときだけ出す。両方とも 0 件の場合は `Issues:` セクション自体を出さない。

   NEEDS_REVISION / FAIL のまま `MAX_ITER` に到達した場合は `PR:` `Merge:` `Cleanup:` `Issues:` 行を出さない。

`/trinity:run` の起動自体がパイプライン全体への明示的な許可（push と PR 作成、起票候補ヒアリングを含む）だが、マージとクリーンアップだけは PR 作成後に `git-merge` スキルが呼ぶ `AskUserQuestion` で改めてユーザーの承認を取る。途中で他の確認プロンプトは挟まない。

## Generator チャンク分割の契約

Generator フェーズはチャンク分割で複数回 `trinity:generator` サブエージェントを順次起動する。各チャンクが独立な Claude CLI ターン予算を持つことで、出力上限超過を回避する。

### チャンク列の決定（plan.md のパース）

Planner が書き出した `${RUN_DIR}/plan.md` の `## 影響範囲` セクションを次の手順で決定的にパースし、チャンク列を組み立てる。

1. `## 影響範囲` セクション配下に `### チャンク N: ...`（N は 1 以上の整数）の H3 サブセクションが 1 個以上存在するか確認する。存在すれば各サブセクションを 1 チャンクとして扱う。各チャンクの「ファイル群（ChunkFiles）」は、そのサブセクション内に箇条書き・コードフェンス・本文 `path` 形式で列挙されたファイルパスから取り出す。
2. `### チャンク N: ...` サブセクションが存在しなければ、`## 影響範囲` テーブル全体を 1 チャンクとして扱う。テーブルの 1 列目（`ファイル / モジュール`）から `path:line` の `path` 部分を抽出してファイル群とする（列順は `ファイル / モジュール | 変更種別 | 理由` を前提とする）。
3. パース結果が空（ファイル群が 0 件）の場合は停止し、`${RUN_DIR}/plan.md` の `## 影響範囲` を確認するようユーザーに報告する。

```shell
# チャンク総数の計算（例: bash/awk による H3 カウント）
CHUNK_TOTAL=$(awk '/^## 影響範囲/{in_sec=1} in_sec && /^### チャンク [0-9]+:/{count++} /^## [^#]/{if(in_sec && !/^## 影響範囲/)in_sec=0} END{print (count>0?count:1)}' "${RUN_DIR}/plan.md")
```

> **Planner への注記**: Planner は `## 影響範囲` 配下に `### チャンク N: <タイトル>` サブセクションを任意で書くことで、Orchestrator のチャンク分割動作を制御できる。`agents/planner.md` 本体は変更しない。

### チャンクごとの順次起動

チャンク総数 `M` を決定したら、`i = 1..M` の順で `trinity:generator` サブエージェントを**順次**起動する（並列起動はしない）。

各チャンク `i` の起動入力:

- `RUN_DIR: <絶対パス>`
- `WORKTREE_DIR: <絶対パス>`
- `BRANCH: <ブランチ名>`
- `Iteration: <n>`
- `ChunkIndex: <i>`
- `ChunkTotal: <M>`
- `ChunkFiles: <i 番目のチャンクのファイル列、カンマ区切り>`

各チャンクは `${RUN_DIR}/gen-<n>-chunk-<i>.md` にレポートを書き、その絶対パスを返す。Orchestrator はそのパスを保持する。

### 停止条件

あるチャンク `i` で Generator が「検証失敗 → 自力修正不能 → コミット未作成」となった場合、後続チャンク（`i+1..M`）を起動せず Orchestrator はループを停止し、ユーザーに次の情報を報告する。

- 失敗したチャンク番号 `i` / `M`
- 最後に書き出されたレポートパス（`${RUN_DIR}/gen-<n>-chunk-<i>.md`）
- 失敗内容

存在しないコミットを Evaluator に渡してはいけない。

### Evaluator への引き渡し

全チャンク成功時、Orchestrator は次のコマンドでイテレーション内最終コミット SHA を取得する。

```shell
LAST_SHA=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
```

Evaluator にはこの 1 つの SHA と `ChunkTotal: <M>` を渡す。Evaluator 側で `ChunkTotal > 1` のときに `git -C "${WORKTREE_DIR}" log --oneline -n <ChunkTotal>` で中間コミットを遡る契約になっているため、各チャンクの中間コミット SHA を個別に渡す必要はない。

## PASS後の起票候補ヒアリング（post-run-issue-suggestions）

### 起動条件

本段は PASS で `git-pull-request` スキル経由の PR 作成（実行手順 4b）が成功したあと、ステップ 4e と 6/7 の前に実施する（実行手順 4d）。

- `NEEDS_REVISION` / `FAIL` で `max_iter` に達した経路では本段を実施せずスキップする。
- 候補が 0 件のときは `AskUserQuestion` を呼ばず、最終出力の `Issues:` 行も出さない。

本段はオーケストレーター（`commands/run.md`）の責務であり、サブエージェント（Planner / Generator / Evaluator）には委譲しない。サブエージェント定義（`agents/*.md`）は変更しない。

### 候補の抽出

次の3系統を候補の抽出元とする。

1. **最新 `${RUN_DIR}/eval-<n>.md` のリスク・懸念 / 次イテレーション / 持ち越し指摘相当のセクション**
2. **同 run の Generator 検証レポート（`${RUN_DIR}/gen-<n>-chunk-*.md`）の NOTES** — 計画外の逸脱・妥協ポイント
3. **PR 本文の「明示的にスコープ外」セクションの項目**

### 候補の整理

各候補を次の2要素に分けて整理する。

- **タイトル候補（短文）**: issue タイトルとして使う1文
- **本文候補**: 背景・期待動作・関連ファイルパス等を含む説明文

候補数が 16 を超える場合は、Evaluator / Generator レポート上の重要度（記載順を上位とみなす等の単純な方針で構わない）で上位 16 件まで残し、それ以下は破棄するか `${RUN_DIR}/skipped-suggestions.md` にメモする。

### ユーザーへの提示（AskUserQuestion）

`AskUserQuestion` を **1コール** で呼ぶ。`multiSelect=true` を指定する。

`AskUserQuestion` のスキーマ上限（1問あたり最大4オプション、1コールあたり最大4問）に従い、候補数に応じて1〜4問へ分割収容する。

| 候補数 | 問数 |
| --- | --- |
| 1〜4 | 1問 |
| 5〜8 | 2問 |
| 9〜12 | 3問 |
| 13〜16 | 4問 |

各オプションのラベル＝候補タイトル、description＝候補本文の要約（短い背景）とする。「Other」は `AskUserQuestion` が自動付与するため、テンプレートには含めない。

### 同意 = 即起票

ユーザーが選択した候補について、**追加の最終確認プロンプトを挟まず**、即 `gh issue create` を1件ずつ連続実行する。

```shell
gh issue create --repo <owner/repo> --title "<title>" --body "<body>"
```

`<owner/repo>` は次のコマンドの出力から抽出する。

```shell
git -C "$WORKTREE_DIR" remote get-url origin
```

`<title>` は当該候補のタイトル候補、`<body>` は本文候補をそのまま使う。

### 拒否候補の保存

`AskUserQuestion` で提示したが選択されなかった候補を `${RUN_DIR}/skipped-suggestions.md` に Markdown 形式で書き出す。各候補について次の情報が見て取れる形にする（細部は裁量）。

- タイトル候補
- 本文候補
- 抽出元（`eval` / `gen NOTES` / `PR スコープ外` のいずれか）

### 起票結果

起票が1件以上発生したとき、最終出力（実行手順 7）の `Issues:` セクションに各 issue URL を1行ずつ列挙する。

## PASS後 trinity プラグイン自身バグ・要望ヒアリング（post-run-trinity-self-issue-suggestions）

### 位置

本段は前段 `post-run-issue-suggestions`（実行手順 4d）が終わった直後・実行手順 6/7（ログ・最終出力）の直前に実施する（実行手順 4e）。前段とは別段として共存し、前段が存在しなくても本段は単体で成立する。

### 起動条件

PASS で `git-pull-request` スキル経由の PR 作成が成功した最終化経路でのみ実施する。

- `NEEDS_REVISION` / `FAIL` で `max_iter` に達した経路では本段を実施せずスキップする。
- 候補が 0 件のときは `AskUserQuestion` を呼ばず、起票結果出力も出さない。

### 候補の抽出

本 run 中の観察（オーケストレーター・Planner / Generator / Evaluator が遭遇した事象）、`${RUN_DIR}/eval-<n>.md`、Generator 検証レポート NOTES の中から、**trinity プラグイン本体（リポジトリ `yjn279/trinity`）の挙動に起因すると判断できるもの** を拾う。

振り分けルール: 「対象が trinity プラグイン本体（このリポジトリ）の挙動か」「対象がユーザーのプロジェクトコードか」で振り分ける。前者のみ本段が拾い、後者は前段 `post-run-issue-suggestions` に任せる。

trinity プラグイン本体に起因する例:

- skill 指示が曖昧でエージェントが解釈を迷った
- hook が期待どおり起動しなかった
- `agents/*.md` の指示が冗長で解釈が割れた
- `commands/run.md` の既存ステップに矛盾があった

### 候補の整理

各候補を次の 2 要素に分けて整理する。

- **タイトル候補（短文）**: issue タイトルとして使う 1 文
- **本文候補**: 背景・期待動作・関連ファイルパス・抽出元の `eval-<n>.md` や Generator NOTES への参照を含む

候補が 16 を超える場合は重要度上位 16 件に絞り、残りを `${RUN_DIR}/skipped-trinity-self-suggestions.md` に書き出す（後述のスキップ候補保存と同じファイル）。

### ユーザーへの提示（AskUserQuestion）

候補が 1 件以上ある場合は `AskUserQuestion`（`multiSelect=true`）を **1 コール** 呼ぶ。候補数に応じて次のルールで問に分割する。

| 候補数 | 問数 |
| --- | --- |
| 1〜4 | 1 問 |
| 5〜8 | 2 問 |
| 9〜12 | 3 問 |
| 13〜16 | 4 問 |

1 問あたり最大 4 オプション、1 コールあたり最大 4 問。各オプションのラベル＝タイトル候補、description＝本文候補の短い要約。「Other」は `AskUserQuestion` が自動付与するためテンプレートに含めない。

本段の `AskUserQuestion` への参加そのものが、issue 起票への承認 touchpoint である。追加の Yes/No 確認は挟まない（「選択 = そのまま起票」と読める）。

### 同意 = 即起票

ユーザーが選択した候補は追加確認プロンプトを挟まず、即 `gh issue create` を 1 件ずつ連続実行する。

```shell
gh issue create --repo yjn279/trinity --title "<title>" --body "<body>"
```

起票先リポジトリは `yjn279/trinity` でハードコードし、`git remote get-url origin` 等の動的解決は使わない（前段 `post-run-issue-suggestions` がユーザーのプロジェクトリポジトリを動的に取得するのと対照的）。

### 拒否候補の保存

提示したが選択されなかった候補は `${RUN_DIR}/skipped-trinity-self-suggestions.md` に書き出す。スキーマは「タイトル候補 / 本文候補 / 抽出元」が見て取れる Markdown であれば足りる。

このファイル名 `skipped-trinity-self-suggestions.md` は、前段 `post-run-issue-suggestions` が使う `${RUN_DIR}/skipped-suggestions.md` とは異なり、ファイル名の衝突は発生しない。

### 起票結果

起票が 1 件以上発生したとき、最終出力（実行手順 7）の `Issues:` セクション内に「trinity プラグイン向け」の連続ブロックとして各 issue URL を 1 行ずつ列挙する。前段 `post-run-issue-suggestions` の起票結果（ユーザープロジェクト向け）と並列に並ぶ。

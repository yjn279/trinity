---
name: git-merge
description: "PR を確認した上でマージし、作業ブランチ・worktree・run ディレクトリ（監査ログを含む）を完結的に片付ける。マージしない場合は改善項目をヒアリングして次回実行用の要件文を返す。"
when-to-use: "PR のマージ確認とクリーンアップが必要なときに使う。呼び出し側から渡すのは PR URL のみ。既定モード・PR continuation モードのどちらでも同じ入力インタフェースで動作する。"
tools: Bash, AskUserQuestion
---

# 役割

PR のマージ確認から後始末まで完結させるスキルである。削除するブランチ名・worktree パス・run ディレクトリ・リポジトリパスはすべてスキル内部で推測する。マージを否認する場合も、ユーザーに後始末を渡さずスキル内で完結する。マージしない選択がされた場合は改善項目をヒアリングし、次回実行用の要件文を整形して返す。

既定モード（新規 PR）と PR continuation モード（既存 PR への追加 push）のどちらから呼ばれた場合でも、このスキルへの入力は **PR URL 1 つのみ** であり、以降の推測・フローはまったく同じである。ブランチ名が `trinity/<TS>-<SLUG>` 形式でなくても（既存 PR の head ブランチ名であっても）動作するように、ブランチ名の prefix に依存しないロジックを使う。

# 受け取る入力

- **PR URL**（文字列）

これ以外のパラメータ（ブランチ名、worktree パス、run ディレクトリのパス、リポジトリパスなど）は呼び出し側から受け取らない。

# スキル内で推測する項目

| 項目 | 推測方法 |
| --- | --- |
| ブランチ名 | PR URL から `gh pr view <PR_URL> --json headRefName` で取得 |
| worktree パス | `git worktree list --porcelain` からブランチ名で照合（命名規約に依存しない） |
| run ディレクトリのパス | worktree パスの親ディレクトリ（`dirname "$WORKTREE_DIR"`） |
| リポジトリのパス | `git -C "$WORKTREE_DIR" rev-parse --show-toplevel` |
| `BASE_BRANCH` | PR の `baseRefName`（`gh pr view <PR_URL> --json baseRefName`） |

# ワークフロー

## ステップ 1: PR 情報を取得する

```shell
gh pr view "$PR_URL" --json headRefName,baseRefName,state,title
```

`BRANCH`（head ref）、`BASE_BRANCH`（base ref）、PR の現在の状態を取得する。

## ステップ 2: worktree パスと run ディレクトリを推測する

`git worktree list --porcelain` の出力から、`BRANCH` に一致する worktree のパスを探す。

ブランチ名が `trinity/` で始まるとは限らない（PR continuation モードでは既存 PR の head ブランチ名が使われる）。`grep -A1 "branch refs/heads/${BRANCH}"` の `${BRANCH}` にはそのまま取得した head ref 名を使えばよく、prefix 形式のチェックは不要である。

```shell
git worktree list --porcelain | grep -A1 "branch refs/heads/${BRANCH}"
```

```shell
WORKTREE_DIR=<上記で取得したパス>
RUN_DIR=$(dirname "$WORKTREE_DIR")
REPO_ROOT=$(git -C "$WORKTREE_DIR" rev-parse --show-toplevel)
LOG_FILE="${REPO_ROOT}/.trinity/trinity.log"
```

## ステップ 3: ユーザーにマージ方針を確認する

`AskUserQuestion` で次の選択肢を提示する。ユーザーに後始末を渡さず、スキルが全フローを完結させる。

> PR「<タイトル>」（<PR URL>）についてどうしますか？
>
> 1. マージする — squash merge してクリーンアップする
> 2. クローズする（マージなし）— PR を close してクリーンアップする
> 3. Draft に戻して改善する — 改善要件をヒアリングし、次回実行用の要件文を返す

PR continuation モードで「既存 PR のレビュアーが触っていたブランチを削除したくない」場合は、この選択肢で「Draft に戻して改善する」を選べば、ブランチ・worktree・run ディレクトリは保持される（ステップ 4c 参照）。追加の確認プロンプトは挟まない。

## ステップ 4a: マージする場合

1. **PR をマージする**

   ```shell
   gh pr merge "$PR_URL" --squash --delete-branch
   ```

2. **ローカルの BASE_BRANCH を最新化する**

   ```shell
   git -C "$REPO_ROOT" checkout "$BASE_BRANCH"
   git -C "$REPO_ROOT" pull --ff-only
   ```

3. **ローカルの作業ブランチを削除する**（`--delete-branch` で既にリモートは削除済みのため）

   ```shell
   git -C "$REPO_ROOT" branch -d "$BRANCH"
   ```

   `BRANCH` が `trinity/<TS>-<SLUG>` 形式であるかに依存しない。ブランチ名はステップ 1 で `gh pr view` から取得した `headRefName` をそのまま使う。

4. **worktree を削除する**

   ```shell
   git -C "$REPO_ROOT" worktree remove "$WORKTREE_DIR" --force
   ```

5. **run ディレクトリ（監査ログを含む）を削除する**

   `plan.md`、`eval-*.md` を含む `${RUN_DIR}` 配下をすべて削除する。

   ```shell
   rm -rf "$RUN_DIR"
   ```

6. **trinity.log に完了行を追記する**

   ```shell
   printf '=== %s run ended: merged ===\n' "$(basename "$RUN_DIR")" >> "$LOG_FILE"
   ```

## ステップ 4b: クローズする（マージなし）場合

1. **PR をクローズする**

   ```shell
   gh pr close "$PR_URL"
   ```

2. **リモートの作業ブランチを削除する**

   ```shell
   git -C "$REPO_ROOT" push origin --delete "$BRANCH"
   ```

3. **ローカルの作業ブランチを削除する**

   ```shell
   git -C "$REPO_ROOT" branch -d "$BRANCH"
   ```

4. **worktree を削除する**

   ```shell
   git -C "$REPO_ROOT" worktree remove "$WORKTREE_DIR" --force
   ```

5. **run ディレクトリ（監査ログを含む）を削除する**

   `plan.md`、`eval-*.md` を含む `${RUN_DIR}` 配下をすべて削除する。

   ```shell
   rm -rf "$RUN_DIR"
   ```

6. **trinity.log に完了行を追記する**

   ```shell
   printf '=== %s run ended: closed ===\n' "$(basename "$RUN_DIR")" >> "$LOG_FILE"
   ```

## ステップ 4c: Draft に戻して改善する場合

1. **PR を Draft 状態に戻す**

   ```shell
   gh pr ready "$PR_URL" --undo
   ```

2. **改善項目をヒアリングする**

   `AskUserQuestion` で具体的な改善要件を尋ねる。ユーザーに後始末作業（ブランチ削除、worktree 削除など）を依頼しない。

   > 改善したい内容を 1〜4 文で教えてください。次回の実行に引き継ぎます。

3. **次回実行用の要件文を整形して返す**

   ユーザーの回答をもとに、次回の実行に投入できる要件文を整形する。呼び出し側（オーケストレーター）はこの要件文を受け取り、新しい実行を開始するか否かを判断する。

   このステップではブランチ・worktree・run ディレクトリの削除は行わない（次回の実行で引き継ぐため）。

# 副作用

| フロー | 副作用 |
| --- | --- |
| マージ | PR のマージ（squash）、リモート＋ローカルのブランチ削除、worktree 削除、run ディレクトリ削除、trinity.log への完了行追記、BASE_BRANCH の `git pull --ff-only` |
| クローズ | PR のクローズ、リモート＋ローカルのブランチ削除、worktree 削除、run ディレクトリ削除、trinity.log への完了行追記 |
| Draft に戻す | PR を Draft に戻す、改善要件のヒアリングのみ（ブランチ・worktree・run ディレクトリは保持） |

いずれのフローも、クリーンアップはユーザーが選択したタイミング（ステップ 3 の `AskUserQuestion` で「マージ」または「クローズ」を選んだとき）にのみ実行される。PR continuation モードで既存 PR のブランチが削除されることをユーザーが望まない場合は「Draft に戻して改善する」を選択することで回避できる。

# 出力

| 項目 | 内容 |
| --- | --- |
| マージ結果 | `merged` / `closed` / `needs-revision-with-followup-requirements` |
| 改善要件文 | `needs-revision` の場合のみ。次回実行用の要件文（呼び出し側が利用するかどうかを判断する） |

---
name: git-pull-request
description: "Generator がコミットを積んだ worktree のブランチを origin に push し、PR を作成または既存 PR に追加 push する。MODE=new-branch では新規 PR を作成する。MODE=existing-pr では fast-forward push のみを行い gh pr create はスキップする。"
when-to-use: "worktree ブランチの push と PR 作成（または既存 PR への追加 push）が必要なときに使う。呼び出し側から渡すのは MODE と PR タイトル・PR 本文（new-branch モード）または MODE と PR_NUMBER（existing-pr モード）のみ。"
tools: Bash
---

# 役割

worktree のブランチを `origin` に push し、Pull Request を作成または既存 PR に追加 push するスキルである。`MODE=new-branch` では push の衝突防止を含む新規 PR 作成を行う。`MODE=existing-pr` では fast-forward 可否を確認した上で既存 PR ブランチへ追加 push するのみで `gh pr create` は呼ばない。worktree パス・ブランチ名・ベースブランチはスキル内部で推測する。

# 受け取る入力

- **`MODE`**（`new-branch` または `existing-pr`）。省略時は `new-branch`
- **PR タイトル**（文字列）— `MODE=new-branch` のときのみ必要
- **PR 本文**（文字列）— `MODE=new-branch` のときのみ必要
- **`PR_NUMBER`**（正の整数）— `MODE=existing-pr` のときのみ必要

`MODE=existing-pr` のとき PR タイトル・PR 本文は受け取らない（追加 push のみを行い PR 本体は更新しない）。

PR 本文の組み立て（plan.md の目的・受け入れ基準の引用、eval レポートの判定セクションの引用など）は呼び出し側の責任で行い、完成した文字列として `MODE=new-branch` のときにこのスキルに渡す。

# スキル内で推測する項目

| 項目 | 推測方法 |
| --- | --- |
| worktree パス | `git worktree list --porcelain` から現在の作業ブランチに紐づく非メイン worktree を選択する |
| ブランチ名 | 上記 worktree の `branch` フィールド（HEAD ref） |
| ベースブランチ | `git merge-base --fork-point <known-base> HEAD` または reflog から、worktree のブランチが分岐した親ブランチを推測する。複数候補になる場合のみユーザーに選択肢を提示する |
| リモート owner/repo | `git -C "$WORKTREE_DIR" remote get-url origin` からパースする |

# ワークフロー

## MODE=new-branch（新規 PR 作成）

### ステップ 1: worktree と作業ブランチを特定する

`git worktree list --porcelain` の出力を解析し、現在進行中の作業が含まれる非メイン worktree（`branch: refs/heads/trinity/` で始まるもの）を選択する。

```shell
git worktree list --porcelain
```

`WORKTREE_DIR` と `BRANCH` を確定する。

### ステップ 2: ベースブランチを推測する

```shell
git -C "$WORKTREE_DIR" log --oneline --decorate | head -20
git -C "$WORKTREE_DIR" for-each-ref --format='%(refname:short)' refs/heads/ | grep -v "^trinity/"
```

reflog とブランチ一覧から、このブランチが切り出された元ブランチ（通常 `main` または `master`）を推測する。候補が一意に決まらない場合のみユーザーに確認する。

### ステップ 3: リモート同名ブランチの存在を確認する（push 上書き防止）

push の前に `git ls-remote --heads origin <branch>` でリモート同名ブランチの存在を確認する。

```shell
git -C "$WORKTREE_DIR" ls-remote --heads origin "$BRANCH"
```

- **リモートにブランチが存在しない場合**: 通常通り push を進める。
- **リモートにブランチが存在する場合**: push を中断し、ユーザーに次のメッセージを通知して停止する。
  > `origin/<branch>` がすでに存在します。上書き push は行いません。リモートブランチを手動で確認・削除した後、再度実行してください。

ブランチ命名に秒精度のタイムスタンプが含まれる場合でも、命名規約に頼らずこのチェックを必ず実施する。

### ステップ 4: push する（ネットワーク要因の再試行付き）

```shell
git -C "$WORKTREE_DIR" push -u origin "$BRANCH"
```

失敗がネットワーク要因（exit code による判定）のときのみ、最大 4 回 exponential backoff で再試行する（2s、4s、8s、16s）。権限エラー・ブランチ保護など、ネットワーク以外の原因による失敗はそのまま停止してユーザーに報告する。

### ステップ 5: PR を作成する

リモート URL から owner/repo を取得し、`gh pr create` で PR を作成する。

```shell
gh pr create \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  --base "$BASE_BRANCH" \
  --head "$BRANCH"
```

`gh` が利用できない環境では `mcp__github__create_pull_request` ツールで代替する。

---

## MODE=existing-pr（既存 PR への追加 push のみ）

### ステップ 1: worktree と作業ブランチを特定する

`git worktree list --porcelain` の出力を解析し、`PR_NUMBER` に対応する head ブランチを持つ non-main worktree を特定する。

```shell
git worktree list --porcelain
```

`WORKTREE_DIR` と `BRANCH` を確定する。

### ステップ 2: リモート同名ブランチの存在を確認する（前提条件）

`MODE=existing-pr` では、リモートに同名ブランチが**存在することが前提条件**である。存在しない場合はエラーとして停止する。

```shell
REMOTE_EXISTS=$(git -C "$WORKTREE_DIR" ls-remote --heads origin "$BRANCH")
if [ -z "$REMOTE_EXISTS" ]; then
  echo "origin/${BRANCH} が存在しません。既存 PR モードではリモートブランチが存在する必要があります。" >&2
  exit 1
fi
```

### ステップ 3: fast-forward 可否を確認する

リモートの HEAD がローカルより先行している場合（fast-forward 不能）は force push を行わず停止する。

```shell
git -C "$WORKTREE_DIR" fetch origin "$BRANCH"
MERGE_BASE=$(git -C "$WORKTREE_DIR" merge-base HEAD "origin/${BRANCH}")
REMOTE_HEAD=$(git -C "$WORKTREE_DIR" rev-parse "origin/${BRANCH}")
LOCAL_HEAD=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

# ローカルがリモートの祖先かどうか確認（fast-forward 可能 = ローカルがリモート以降にある）
REMOTE_IS_ANCESTOR=$(git -C "$WORKTREE_DIR" merge-base --is-ancestor "origin/${BRANCH}" HEAD && echo "yes" || echo "no")
```

- **fast-forward 可能（ローカルがリモートより先行、またはリモートと同一）**: push を進める。
- **fast-forward 不能（リモート HEAD がローカルより先行）**: force push は行わず、停止してユーザーに次を案内する。
  > `origin/${BRANCH}` のリモート HEAD がローカルより先行しています。force push は行いません。`git pull --rebase origin ${BRANCH}` でローカルをリベースした後、再度実行してください。

### ステップ 4: push する（ネットワーク要因の再試行付き）

force push は使わない（`-u` フラグも不要）。

```shell
git -C "$WORKTREE_DIR" push origin "$BRANCH"
```

失敗がネットワーク要因のときのみ、最大 4 回 exponential backoff で再試行する（2s、4s、8s、16s）。それ以外の失敗はそのまま停止してユーザーに報告する。

### ステップ 5: 既存 PR の URL を取得する（PR 作成は行わない）

`gh pr create` は呼ばない。入力の `PR_NUMBER` から既存 PR の URL を取得して返す。

```shell
PR_URL=$(gh pr view "${PR_NUMBER}" --json url -q .url)
```

---

# 副作用

| モード | 副作用 |
| --- | --- |
| `new-branch` | `git push -u origin <branch>` を実行し、リモートにブランチを作成する。`gh pr create` または `mcp__github__create_pull_request` で新規 PR を作成する |
| `existing-pr` | `git push origin <branch>` を実行し、既存リモートブランチを fast-forward で更新する。PR 作成は行わない |

# 出力

| 項目 | 内容 |
| --- | --- |
| `PR_NUMBER` | PR 番号（`new-branch` モード: 新規作成した PR 番号。`existing-pr` モード: 入力で渡した PR 番号） |
| `PR_URL` | PR の URL（`new-branch` モード: 新規作成した PR の URL。`existing-pr` モード: 既存 PR の URL） |
| `PR_REUSED` | `false`（`new-branch` モード）または `true`（`existing-pr` モード） |
| push 結果 | push 成功 / 失敗 / 中断（リモート同名ブランチ存在 / fast-forward 不能） |

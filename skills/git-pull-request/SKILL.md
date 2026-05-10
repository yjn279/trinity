---
name: git-pull-request
description: "Generator がコミットを積んだ worktree のブランチを origin に push し、PR を作成する。PR_NUMBER が渡されたときは新規 PR を作らず、その既存 PR のブランチへ追加 push のみを行う。"
when-to-use: "worktree ブランチの push と PR 作成（または既存 PR の継続 push）が必要なときに使う。新規 PR を作る場合は PR タイトルと PR 本文を、既存 PR を継続する場合は PR_NUMBER を渡す。"
tools: Bash
---

# 役割

worktree のブランチを `origin` に push し、PR を作成または既存 PR を継続するスキルである。`PR_NUMBER` が渡されたかどうかで挙動が自然に分かれる。

- **`PR_NUMBER` が渡されない場合**: push の衝突防止を含む新規 PR 作成を行う。
- **`PR_NUMBER` が渡された場合**: fast-forward 可否を確認した上でその既存 PR のブランチへ追加 push のみを行い、`gh pr create` は呼ばない。

worktree パス・ブランチ名・ベースブランチはスキル内部で推測する。

# 受け取る入力

- **`PR_NUMBER`**（正の整数、任意）— 既存 PR を継続する場合に渡す
- **PR タイトル**（文字列）— `PR_NUMBER` を渡さない場合に必須
- **PR 本文**（文字列）— `PR_NUMBER` を渡さない場合に必須

`PR_NUMBER` を渡したときは PR タイトル・PR 本文は受け取らない（追加 push のみで PR 本体は更新しない）。

PR 本文の組み立て（plan.md の目的・受け入れ基準の引用、eval レポートの判定セクションの引用など）は呼び出し側の責任で行い、完成した文字列としてこのスキルに渡す。

# スキル内で推測する項目

| 項目 | 推測方法 |
| --- | --- |
| worktree パス | `git worktree list --porcelain` から現在の作業ブランチに紐づく非メイン worktree を選択する |
| ブランチ名 | 上記 worktree の `branch` フィールド（HEAD ref） |
| ベースブランチ | `git merge-base --fork-point <known-base> HEAD` または reflog から、worktree のブランチが分岐した親ブランチを推測する。複数候補になる場合のみユーザーに選択肢を提示する |
| リモート owner/repo | `git -C "$WORKTREE_DIR" remote get-url origin` からパースする |

# ワークフロー

## ステップ 1: worktree と作業ブランチを特定する

`git worktree list --porcelain` の出力を解析し、対象の worktree（`PR_NUMBER` がある場合は PR の head ブランチを持つ worktree、ない場合は `branch: refs/heads/trinity/` で始まる非メイン worktree）を選択する。

```shell
git worktree list --porcelain
```

`WORKTREE_DIR` と `BRANCH` を確定する。

## ステップ 2: ベースブランチを推測する

```shell
git -C "$WORKTREE_DIR" log --oneline --decorate | head -20
git -C "$WORKTREE_DIR" for-each-ref --format='%(refname:short)' refs/heads/ | grep -v "^trinity/"
```

reflog とブランチ一覧から、このブランチが切り出された元ブランチ（通常 `main` または `master`）を推測する。候補が一意に決まらない場合のみユーザーに確認する。

## ステップ 3: リモート同名ブランチの状態を確認する

`PR_NUMBER` の有無で期待する状態が逆になるので、両者で扱いが異なる。

```shell
REMOTE_EXISTS=$(git -C "$WORKTREE_DIR" ls-remote --heads origin "$BRANCH")
```

**`PR_NUMBER` が渡されていない場合（新規 PR を作る経路）**:

リモートに同名ブランチが存在しない前提である。存在した場合は push の上書きを避けるため停止する。

- リモートにブランチが存在しない → 通常通り進む。
- リモートにブランチが存在する → push を中断し、ユーザーに通知して停止する。

  > `origin/<branch>` がすでに存在します。上書き push は行いません。リモートブランチを手動で確認・削除した後、再度実行してください。

ブランチ命名に秒精度のタイムスタンプが含まれる場合でも、命名規約に頼らずこのチェックを必ず実施する。

**`PR_NUMBER` が渡されている場合（既存 PR を継続する経路）**:

リモートに同名ブランチが存在することが前提である。存在しない場合はエラーとして停止する。

```shell
if [ -z "$REMOTE_EXISTS" ]; then
  echo "origin/${BRANCH} が存在しません。既存 PR の継続にはリモートブランチが存在する必要があります。" >&2
  exit 1
fi
```

続いて fast-forward 可否を確認する。リモート HEAD がローカルより先行している場合（fast-forward 不能）は force push を行わず停止する。

```shell
git -C "$WORKTREE_DIR" fetch origin "$BRANCH"
REMOTE_IS_ANCESTOR=$(git -C "$WORKTREE_DIR" merge-base --is-ancestor "origin/${BRANCH}" HEAD && echo "yes" || echo "no")
```

- fast-forward 可能（ローカルがリモートより先行、または同一）→ push を進める。
- fast-forward 不能（リモート HEAD がローカルより先行）→ force push は行わず停止し、ユーザーに次を案内する。

  > `origin/${BRANCH}` のリモート HEAD がローカルより先行しています。force push は行いません。`git pull --rebase origin ${BRANCH}` でローカルをリベースした後、再度実行してください。

## ステップ 4: push する（ネットワーク要因の再試行付き）

```shell
# 新規 PR 経路: アップストリームを設定する
git -C "$WORKTREE_DIR" push -u origin "$BRANCH"

# 既存 PR 経路: 既にアップストリームが設定済みの前提で push のみ。force push は使わない
git -C "$WORKTREE_DIR" push origin "$BRANCH"
```

失敗がネットワーク要因（exit code による判定）のときのみ、最大 4 回 exponential backoff で再試行する（2s、4s、8s、16s）。権限エラー・ブランチ保護など、ネットワーク以外の原因による失敗はそのまま停止してユーザーに報告する。

## ステップ 5: PR を確定する

**`PR_NUMBER` が渡されていない場合**: リモート URL から owner/repo を取得し、`gh pr create` で PR を作成する。

```shell
gh pr create \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  --base "$BASE_BRANCH" \
  --head "$BRANCH"
```

`gh` が利用できない環境では `mcp__github__create_pull_request` ツールで代替する。

**`PR_NUMBER` が渡されている場合**: `gh pr create` は呼ばない。入力の `PR_NUMBER` から既存 PR の URL を取得して返す。

```shell
PR_URL=$(gh pr view "${PR_NUMBER}" --json url -q .url)
```

# 副作用

| 経路 | 副作用 |
| --- | --- |
| 新規 PR | `git push -u origin <branch>` を実行し、リモートにブランチを作成する。`gh pr create` または `mcp__github__create_pull_request` で新規 PR を作成する |
| 既存 PR 継続 | `git push origin <branch>` を実行し、既存リモートブランチを fast-forward で更新する。PR 作成は行わない |

# 出力

| 項目 | 内容 |
| --- | --- |
| `PR_NUMBER` | PR 番号（新規経路: 新規作成した PR 番号。継続経路: 入力で渡した PR 番号） |
| `PR_URL` | PR の URL（新規経路: 新規作成した PR の URL。継続経路: 既存 PR の URL） |
| push 結果 | push 成功 / 失敗 / 中断（リモート同名ブランチ存在 / fast-forward 不能） |

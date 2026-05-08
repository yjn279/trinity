---
name: git-merge
description: 呼び出し側でマージ可否確認が済んでいる前提で、squash マージ・リモートブランチ削除・worktree 削除・ローカルブランチ削除・追加削除パスの削除までを実行する。マージ失敗時の停止規約、クリーンアップの順序とフォールバックを規定する。`AskUserQuestion` は本スキルに含まれない。マージ可否確認は呼び出し側（commands/run.md）の責務である。
---

# git-merge

本スキルは **承認が取れている前提** で動く。ユーザーへのマージ可否確認は呼び出し側（`commands/run.md`）が行い、承認が取れた場合のみ本スキルを呼ぶ。否認時のヒアリングも呼び出し側の責務であり、本スキルは `declined` の分岐を扱わない。

## 入力契約

呼び出し側から次を受け取る。`OWNER` / `REPO` / `EXTRA_CLEANUP_PATHS` は呼び出し側から受け取らない。これらはすべてスキル内で組み立てる。

- `PR_NUMBER` — マージ対象 PR の番号
- `BRANCH` — マージ後に削除するブランチ名
- `WORKTREE_PATH` — 削除する worktree の絶対パス
- `RUN_DIR` — クリーンアップで `rm -rf` する run ディレクトリの絶対パス
- `REPO_ROOT` — `git -C` で叩く起動側リポジトリのルートパス

## スキル内での変数組み立て

```shell
# origin URL から OWNER / REPO を取り出す
ORIGIN_URL=$(git -C "$WORKTREE_PATH" remote get-url origin)
# https://github.com/<owner>/<repo>.git または git@github.com:<owner>/<repo>.git のどちらにも対応
# 末尾の .git は剥がす

EXTRA_CLEANUP_PATHS=["$RUN_DIR"]
```

`https://github.com/<owner>/<repo>.git` と `git@github.com:<owner>/<repo>.git` のどちらにも対応する。末尾の `.git` は剥がす。

## マージ実行

`mcp__github__merge_pull_request` を使う。スキーマが未ロードなら呼ぶ前に読み込む。

```
ToolSearch query="select:mcp__github__merge_pull_request"
```

`OWNER` / `REPO` / `PR_NUMBER` を使う。マージ方式は `squash` に固定する。

マージ失敗（コンフリクト、ブランチ保護違反、必須レビュー未完了、CI 失敗待ちなど）は**再試行せずに停止**し、エラー文言と PR_NUMBER を呼び出し側に返す。クリーンアップには進まない。

## クリーンアップ（マージ成功時のみ）

次の手順を順に実行する。1 ステップが失敗した場合はフォールバックで完結させる。すべてのフォールバックでも失敗した場合のみ、その特定のステップのみを呼び出し側に伝える。`partial:` 戻り値は各ステップのフォールバックをすべて尽くしてもなお完結できなかった場合の最終安全弁であり、フォールバックを試さずに返すことはしない。

### 1. リモートブランチの削除

```shell
git -C "$WORKTREE_PATH" push origin --delete "$BRANCH"
```

失敗した場合は次のフォールバックで再試行する。

```shell
gh api -X DELETE "repos/$OWNER/$REPO/git/refs/heads/$BRANCH"
```

その後、起動側リポジトリのリモート追跡参照を更新する。

```shell
git -C "$REPO_ROOT" fetch --prune origin
```

### 2. worktree の削除

```shell
git -C "$REPO_ROOT" worktree remove "$WORKTREE_PATH"
```

失敗した場合は `--force` 付きで再試行する。

```shell
git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_PATH"
```

それでも失敗した場合は `rm -rf` と `worktree prune` で完結させる。

```shell
rm -rf "$WORKTREE_PATH" && git -C "$REPO_ROOT" worktree prune
```

### 3. ローカルブランチの削除

```shell
git -C "$REPO_ROOT" branch -D "$BRANCH"
```

失敗した場合は次のフォールバックで完結させる。

```shell
git -C "$REPO_ROOT" update-ref -d "refs/heads/$BRANCH"
```

### 4. `EXTRA_CLEANUP_PATHS` の削除

スキル内で組み立てた `EXTRA_CLEANUP_PATHS`（= `[$RUN_DIR]`）の各パスに対して順に実行する。

```shell
rm -rf "$path"
```

## 戻り値

- `MERGE_RESULT` ∈ { `merged`, `failed: <理由>` }
- `CLEANUP_RESULT` ∈ { `done`, `partial: <残っている操作>` }

`declined` は返さない。マージ可否確認は呼び出し側（`commands/run.md`）の責務であり、本スキルは承認済みの状態でのみ呼ばれる。

## やってはいけないこと

- マージ失敗を再試行する（コンフリクトもブランチ保護違反も再試行で解決しない）
- マージ方式を `merge` や `rebase` にする（`squash` で固定）
- `worktree remove --force` を最初から打つ（dirty を握りつぶすので、まず非 force で試す）
- クリーンアップの各ステップでフォールバックを試さずに即座に呼び出し側に投げる
- `OWNER` / `REPO` / `EXTRA_CLEANUP_PATHS` を呼び出し側から受け取る（スキル内の責務）

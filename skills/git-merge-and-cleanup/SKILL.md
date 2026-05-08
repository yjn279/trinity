---
name: git-merge-and-cleanup
description: PR 作成直後にマージ可否をユーザーに確認し、承認時のみ squash マージ・リモートブランチ削除・worktree 削除・ローカルブランチ削除・追加削除パスの削除までを実行する。`AskUserQuestion` は最大 2 回（マージ確認 1 回 + 否認時のヒアリング 1 回）。マージ失敗時の停止規約、お片付けの順序とフォールバックを規定する。
---

# git-merge-and-cleanup

PR 作成直後のマージ確認からお片付けまでを担う。「マージしてお片付け」と「PR を残して改善項目をヒアリングする」の 2 分岐をユーザーに 1 回だけ問い、承認時にすべてを完結させる。

## 入力契約

呼び出し側から次を受け取る。

- `OWNER` — リポジトリオーナー
- `REPO` — リポジトリ名
- `PR_NUMBER` — マージ対象 PR の番号
- `PR_URL` — PR の URL
- `BRANCH` — マージ後に削除するブランチ名
- `WORKTREE_PATH` — 削除する worktree の絶対パス
- `REPO_ROOT` — `git -C` で叩く起動側リポジトリのルートパス
- `EXTRA_CLEANUP_PATHS`（任意） — マージ成功時に追加で `rm -rf` する絶対パスの配列
- `CONFIRM_QUESTION`（任意） — `AskUserQuestion` の 1 回目の質問文。省略時は本スキルの既定文を使う
- `CONFIRM_OPTIONS`（任意） — `AskUserQuestion` の 1 回目の選択肢。省略時は本スキルの既定選択肢を使う
- `FOLLOWUP_QUESTION`（任意） — 否認時の `AskUserQuestion` の質問文。省略時は本スキルの既定文を使う

## マージ確認

PR 作成直後に `AskUserQuestion` を 1 回目として呼ぶ。`AskUserQuestion` の合計呼び出し回数は最大 2 回（マージ確認 1 回 + 否認時のヒアリング 1 回）に限定する。

`CONFIRM_QUESTION` が渡された場合はその文を、渡されなければ次の既定文を使う。

- 既定の質問: `PR #<PR_NUMBER> (<PR_URL>) を作成しました。マージしてお片付けまで進めますか？`

`CONFIRM_OPTIONS` が渡された場合はその選択肢を、渡されなければ次の既定選択肢を使う。

- 既定の選択肢 1: `マージしてお片付け (Recommended)`
- 既定の選択肢 2: `PR は残して改善項目を相談する`

`Other`（自由入力）は `AskUserQuestion` が自動で付与する。`Other` の回答が「マージしてお片付け」と明確に解釈できる場合は選択肢 1 扱い。それ以外は選択肢 2 扱いとし、ヒアリングを続ける。判定に迷ったら選択肢 2（ヒアリング側）に倒す。

## マージ実行（承認時のみ）

`mcp__github__merge_pull_request` を使う。スキーマが未ロードなら呼ぶ前に読み込む。

```
ToolSearch query="select:mcp__github__merge_pull_request"
```

`OWNER` / `REPO` / `PR_NUMBER` を使う。マージ方式は `squash` に固定する。

マージ失敗（コンフリクト、ブランチ保護違反、必須レビュー未完了、CI 失敗待ちなど）は**再試行せずに停止**し、エラー文言と `PR_URL` を呼び出し側に返す。お片付けには進まない。

## お片付け（マージ成功時のみ）

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

`EXTRA_CLEANUP_PATHS` が渡された場合、配列の各パスに対して順に実行する。

```shell
rm -rf "$path"
```

`EXTRA_CLEANUP_PATHS` が渡されなければ本ステップはスキップする。

## 否認時のヒアリング

ユーザーが選択肢 2（または `Other` で 2 番目扱いになった）場合、マージとお片付けは行わない。`AskUserQuestion` を 2 回目として 1 回だけ呼び、改善項目をヒアリングする。

`FOLLOWUP_QUESTION` が渡された場合はその文を、渡されなければ次の既定文を使う。

- 既定の質問: `改善したい内容を教えてください。`
- 選択肢: なし（自由入力）

ユーザーの回答を受け取ったら、`Followup: <回答>` として呼び出し側へ返す。これ以上 `AskUserQuestion` を呼ばない。

## 戻り値

- `MERGE_RESULT` ∈ { `merged`, `declined`, `failed: <理由>` }
- `CLEANUP_RESULT` ∈ { `done`, `skipped`, `partial: <残っている操作>` }
- `FOLLOWUP`（否認時のみ）— ユーザーの回答をそのまま

## やってはいけないこと

- `AskUserQuestion` を 3 回以上呼ぶ（合計最大 2 回まで）
- マージ失敗を再試行する（コンフリクトもブランチ保護違反も再試行で解決しない）
- マージ方式を `merge` や `rebase` にする（`squash` で固定）
- `worktree remove --force` を最初から打つ（dirty を握りつぶすので、まず非 force で試す）
- お片付けの各ステップでフォールバックを試さずに即座に呼び出し側に投げる
- 否認時にマージやお片付けを勝手に実行する

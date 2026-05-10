---
name: git-worktree
description: "隔離 worktree を作成するスキル。PR_NUMBER が渡されない場合は origin/<デフォルトブランチ> を base として新規ブランチを切る。PR_NUMBER が渡された場合はその PR の head ブランチを worktree にチェックアウトする（新規ブランチは作らない）。"
when-to-use: "隔離された git worktree が必要なときに使う。新規ブランチで始める場合はスラッグのみ渡す。既存 PR を継続する場合は PR_NUMBER とスラッグを渡す。"
tools: Bash
---

# 役割

隔離 worktree を作成するスキルである。`PR_NUMBER` が渡されたかどうかで挙動が自然に分かれる。

- **`PR_NUMBER` が渡されない場合**: スラッグから `trinity/<TS>-<SLUG>` 形式の新規ブランチを作り、`origin/<デフォルトブランチ>` の最新コミットを base として worktree にチェックアウトする（現在の作業ブランチには依存しない）。
- **`PR_NUMBER` が渡された場合**: その PR の head ブランチを worktree にチェックアウトする。新規ブランチは作らない。

タイムスタンプとログ追記まで行い、後続の処理に必要なパスとブランチ名を返す。

# 受け取る入力

- **スラッグ**（kebab-case 2〜5 語、要件または PR タイトルから派生）。例: `add-theme-toggle`
- **`PR_NUMBER`**（正の整数、任意）— 既存 PR を継続する場合に渡す

これ以外のパラメータ（リポジトリパス、ログファイルパス、ベースブランチ名など）は呼び出し側から受け取らない。

# スキル内で推測する項目

| 項目 | 推測方法 |
| --- | --- |
| リポジトリルート | `git rev-parse --show-toplevel` |
| `DEFAULT_BRANCH` | `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`（`gh` 不在時は `git symbolic-ref refs/remotes/origin/HEAD \| sed 's@^refs/remotes/origin/@@'`） |
| タイムスタンプ | `date -u +%Y%m%dT%H%M%SZ` |
| ログファイルパス | `<リポジトリルート>/.trinity/trinity.log` |
| タイムスタンプ衝突時 | スラッグ末尾に `-2` `-3` … を付けて一意化する |

# ワークフロー

## ステップ 1: 共通の前準備

リポジトリルートとデフォルトブランチを取得する。

```shell
REPO_ROOT=$(git rev-parse --show-toplevel)

# gh が使える場合
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)

# gh 不在の場合
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
fi
```

タイムスタンプと run ディレクトリ名を決定する。

```shell
TS=$(date -u +%Y%m%dT%H%M%SZ)
SLUG=<呼び出し側から受け取った kebab-case スラッグ>
RUN_NAME="${TS}-${SLUG}"
```

同一タイムスタンプで衝突（`${REPO_ROOT}/.trinity/${RUN_NAME}` がすでに存在する）した場合は `SLUG` 末尾に `-2` `-3` を付けて一意化する。

```shell
RUN_DIR="${REPO_ROOT}/.trinity/${RUN_NAME}"
WORKTREE_DIR="${RUN_DIR}/worktree"
LOG_FILE="${REPO_ROOT}/.trinity/trinity.log"
mkdir -p "${RUN_DIR}"
```

## ステップ 2: PR_NUMBER の有無で分岐する

`PR_NUMBER` が渡されたかどうかで以降の動きが自然に変わる。

### `PR_NUMBER` が渡されていない場合（新規ブランチ経路）

ブランチ名と base を確定する。

```shell
BRANCH="trinity/${RUN_NAME}"
BASE_BRANCH="${DEFAULT_BRANCH}"
```

`origin/<DEFAULT_BRANCH>` の最新を fetch し、そこから派生する新規ブランチを worktree にチェックアウトする。現在の作業ブランチには依存しない。

```shell
git fetch origin "${DEFAULT_BRANCH}"
git worktree add -b "${BRANCH}" "${WORKTREE_DIR}" "origin/${DEFAULT_BRANCH}"
```

trinity.log に開始行を追記する。

```shell
mkdir -p "${REPO_ROOT}/.trinity"
printf '=== %s run started on %s (base=%s) ===\n' \
  "${RUN_NAME}" "${BRANCH}" "${BASE_BRANCH}" >> "${LOG_FILE}"
```

### `PR_NUMBER` が渡されている場合（既存 PR 継続経路）

PR の状態を確認する。open でなければ停止する（closed または merged の PR への追加 push は行わない）。

```shell
PR_STATE=$(gh pr view "${PR_NUMBER}" --json state -q .state 2>/dev/null)
if [ "$PR_STATE" != "OPEN" ]; then
  echo "PR #${PR_NUMBER} は現在 ${PR_STATE} 状態です。open の PR のみ対象にできます。処理を停止します。" >&2
  exit 1
fi
```

PR 情報を取得する。

```shell
PR_HEAD_BRANCH=$(gh pr view "${PR_NUMBER}" --json headRefName -q .headRefName)
PR_BASE_BRANCH=$(gh pr view "${PR_NUMBER}" --json baseRefName -q .baseRefName)
PR_URL=$(gh pr view "${PR_NUMBER}" --json url -q .url)

BRANCH="${PR_HEAD_BRANCH}"
BASE_BRANCH="${PR_BASE_BRANCH}"
```

ローカルブランチ・worktree の競合を確認する。

```shell
LOCAL_BRANCH=$(git branch --list "${BRANCH}")
WORKTREE_IN_USE=$(git worktree list --porcelain | grep "branch refs/heads/${BRANCH}")
```

- ローカルブランチが存在し worktree で使用中 → 停止し、既に同一ブランチがチェックアウトされている旨をユーザーに報告する。`--resume` の利用を案内する。
- ローカルブランチが存在するが worktree 未使用 → 既存ローカルブランチを削除してから新規 worktree を作成する。
- ローカルブランチが存在しない → 通常通り worktree を作成する。

PR の head ブランチを fetch し、worktree にチェックアウトする。新規ブランチは作らない。

```shell
git fetch origin "${PR_HEAD_BRANCH}"

if [ -n "$LOCAL_BRANCH" ] && [ -z "$WORKTREE_IN_USE" ]; then
  git branch -D "${BRANCH}"
fi

git worktree add "${WORKTREE_DIR}" "origin/${PR_HEAD_BRANCH}"
git -C "${WORKTREE_DIR}" checkout -b "${PR_HEAD_BRANCH}" --track "origin/${PR_HEAD_BRANCH}" 2>/dev/null || \
  git -C "${WORKTREE_DIR}" checkout "${PR_HEAD_BRANCH}"
```

trinity.log に開始行を追記する（PR 番号も記録する）。

```shell
mkdir -p "${REPO_ROOT}/.trinity"
printf '=== %s run started on %s (continuing PR #%s, base=%s) ===\n' \
  "${RUN_NAME}" "${BRANCH}" "${PR_NUMBER}" "${BASE_BRANCH}" >> "${LOG_FILE}"
```

# 副作用

- `${RUN_DIR}/` ディレクトリを新規作成する。
- `git worktree add` で `${WORKTREE_DIR}/` にブランチをチェックアウトする。
  - 新規ブランチ経路: 新規ブランチを `origin/<DEFAULT_BRANCH>` から派生させて作成する。
  - 既存 PR 継続経路: PR の head ブランチを既存ブランチとしてチェックアウトする（新規ブランチは作らない）。
- `${LOG_FILE}` に開始行を 1 行追記する。

# 出力

後続の処理のために次の値を返す。

| 変数 | 内容 |
| --- | --- |
| `RUN_DIR` | run ディレクトリの絶対パス（例: `/path/to/repo/.trinity/20260429T153000Z-add-theme-toggle`） |
| `WORKTREE_DIR` | worktree の絶対パス（`${RUN_DIR}/worktree`） |
| `BRANCH` | ブランチ名（新規ブランチ経路: `trinity/<TS>-<SLUG>` 形式。既存 PR 継続経路: PR の head ブランチ名） |
| `BASE_BRANCH` | base ブランチ名（新規ブランチ経路: `DEFAULT_BRANCH`（例: `main`）。既存 PR 継続経路: PR の base ブランチ名） |
| `PR_NUMBER` | 既存 PR 継続経路のみ。引数で渡した PR 番号 |
| `PR_URL` | 既存 PR 継続経路のみ。PR の URL |

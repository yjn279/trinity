---
name: git-worktree
description: "隔離 worktree を作成するスキル。通常モード（new-branch）では origin/<デフォルトブランチ> を base として新規ブランチを切る。既存 PR モード（existing-pr）では PR 番号を受け取り PR の head ブランチを worktree にチェックアウトする。"
when-to-use: "隔離された git worktree が必要なときに使う。通常モードではスラッグのみ渡す。既存 PR モードでは PR_NUMBER とスラッグを渡す。"
tools: Bash
---

# 役割

隔離 worktree を作成するスキルである。通常モード（`MODE=new-branch`）ではスラッグのみを受け取り、`origin/<デフォルトブランチ>` を base として新規ブランチを切る（現在の作業ブランチには依存しない）。既存 PR モード（`MODE=existing-pr`）では PR 番号を受け取り、PR の head ブランチを worktree にチェックアウトする（新規ブランチを作らない）。タイムスタンプとログ追記まで行い、後続の処理に必要なパスとブランチ名を返す。

# 受け取る入力

- **スラッグ**（kebab-case 2〜5 語、要件から派生）。例: `add-theme-toggle`
- **`PR_NUMBER`**（正の整数、`--pr=<N>` 由来）。`MODE=existing-pr` のときのみ。`MODE=new-branch` のときは不要

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

## 共通: リポジトリルートとデフォルトブランチを取得する

```shell
REPO_ROOT=$(git rev-parse --show-toplevel)

# gh が使える場合
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)

# gh 不在の場合
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
fi
```

## モード分岐

呼び出し側から `PR_NUMBER` が渡された場合は `MODE=existing-pr` で動作する。渡されなかった場合は `MODE=new-branch` で動作する。

---

## MODE=new-branch（通常モード）

### ステップ 1: タイムスタンプと run ディレクトリ名を決定する

```shell
TS=$(date -u +%Y%m%dT%H%M%SZ)
SLUG=<呼び出し側から受け取った kebab-case スラッグ>
RUN_NAME="${TS}-${SLUG}"
```

同一タイムスタンプで衝突（`${REPO_ROOT}/.trinity/${RUN_NAME}` がすでに存在する）した場合は `SLUG` 末尾に `-2` `-3` を付けて一意化する。

### ステップ 2: パスとブランチ名を確定する

```shell
RUN_DIR="${REPO_ROOT}/.trinity/${RUN_NAME}"
WORKTREE_DIR="${RUN_DIR}/worktree"
BRANCH="trinity/${RUN_NAME}"
LOG_FILE="${REPO_ROOT}/.trinity/trinity.log"
BASE_BRANCH="${DEFAULT_BRANCH}"
```

### ステップ 3: origin/<デフォルトブランチ> から worktree を作成する

現在の作業ブランチには依存しない。必ず `origin/<DEFAULT_BRANCH>` の最新コミットを base とする。

```shell
git fetch origin "${DEFAULT_BRANCH}"
mkdir -p "${RUN_DIR}"
git worktree add -b "${BRANCH}" "${WORKTREE_DIR}" "origin/${DEFAULT_BRANCH}"
```

### ステップ 4: trinity.log に開始行を追記する

`LOG_FILE` が存在しない場合は作成してから追記する。

```shell
mkdir -p "${REPO_ROOT}/.trinity"
printf '=== %s run started on %s (base=%s) ===\n' \
  "${RUN_NAME}" "${BRANCH}" "${BASE_BRANCH}" >> "${LOG_FILE}"
```

---

## MODE=existing-pr（既存 PR モード）

### 事前チェック: PR の状態を確認する

PR が open でなければ停止して報告する。closed または merged の PR への追加 push は行わない。

```shell
PR_STATE=$(gh pr view "${PR_NUMBER}" --json state -q .state 2>/dev/null)
if [ "$PR_STATE" != "OPEN" ]; then
  echo "PR #${PR_NUMBER} は現在 ${PR_STATE} 状態です。open の PR のみ対象にできます。処理を停止します。" >&2
  exit 1
fi
```

### ステップ 1: PR 情報を取得する

```shell
PR_HEAD_BRANCH=$(gh pr view "${PR_NUMBER}" --json headRefName -q .headRefName)
PR_BASE_BRANCH=$(gh pr view "${PR_NUMBER}" --json baseRefName -q .baseRefName)
PR_TITLE=$(gh pr view "${PR_NUMBER}" --json title -q .title)
PR_URL=$(gh pr view "${PR_NUMBER}" --json url -q .url)
```

スラッグは呼び出し側から受け取った値を使う（PR タイトルから派生させた kebab-case スラッグ）。

### ステップ 2: タイムスタンプと run ディレクトリ名を決定する

```shell
TS=$(date -u +%Y%m%dT%H%M%SZ)
RUN_NAME="${TS}-${SLUG}"
```

同一タイムスタンプで衝突（`${REPO_ROOT}/.trinity/${RUN_NAME}` がすでに存在する）した場合は `SLUG` 末尾に `-2` `-3` を付けて一意化する。

### ステップ 3: パスを確定する

```shell
RUN_DIR="${REPO_ROOT}/.trinity/${RUN_NAME}"
WORKTREE_DIR="${RUN_DIR}/worktree"
BRANCH="${PR_HEAD_BRANCH}"
LOG_FILE="${REPO_ROOT}/.trinity/trinity.log"
BASE_BRANCH="${PR_BASE_BRANCH}"
```

既存 PR モードでは新規ブランチを作らず、PR の head ブランチ名をそのまま `BRANCH` に使う。

### ステップ 4: ローカルブランチ・worktree の競合を確認する

PR の head ブランチがローカルに既に存在する場合、または worktree に既にチェックアウト済みの場合は、次のいずれかを確認してから進む。

```shell
# ローカルブランチの存在確認
LOCAL_BRANCH=$(git branch --list "${BRANCH}")

# worktree での使用確認
WORKTREE_IN_USE=$(git worktree list --porcelain | grep "branch refs/heads/${BRANCH}")
```

- **ローカルブランチが存在し worktree で使用中の場合**: 停止し、既に `${WORKTREE_DIR}` に同一ブランチがチェックアウトされている旨をユーザーに報告する。`--resume` モードの利用を案内する。
- **ローカルブランチが存在するが worktree 未使用の場合**: 既存ローカルブランチを削除してから新規 worktree を作成する（下記参照）。
- **ローカルブランチが存在しない場合**: 通常通り worktree を作成する。

### ステップ 5: worktree を作成する

PR の head ブランチを fetch し、worktree にチェックアウトする。

```shell
git fetch origin "${PR_HEAD_BRANCH}"
mkdir -p "${RUN_DIR}"

if [ -n "$LOCAL_BRANCH" ] && [ -z "$WORKTREE_IN_USE" ]; then
  # 既存ローカルブランチを削除してから worktree 作成
  git branch -D "${BRANCH}"
fi

# 新規ブランチは作らず origin の head ブランチを直接チェックアウト
git worktree add "${WORKTREE_DIR}" "origin/${PR_HEAD_BRANCH}"
# ローカル追跡ブランチを head と同名にする
git -C "${WORKTREE_DIR}" checkout -b "${PR_HEAD_BRANCH}" --track "origin/${PR_HEAD_BRANCH}" 2>/dev/null || \
  git -C "${WORKTREE_DIR}" checkout "${PR_HEAD_BRANCH}"
```

### ステップ 6: trinity.log に開始行を追記する

```shell
mkdir -p "${REPO_ROOT}/.trinity"
printf '=== %s run started on %s (existing-pr=#%s base=%s) ===\n' \
  "${RUN_NAME}" "${BRANCH}" "${PR_NUMBER}" "${BASE_BRANCH}" >> "${LOG_FILE}"
```

---

# 副作用

- `${RUN_DIR}/` ディレクトリを新規作成する。
- `git worktree add` で `${WORKTREE_DIR}/` にブランチをチェックアウトする。
  - `new-branch` モード: 新規ブランチを `origin/<DEFAULT_BRANCH>` から派生させて作成する。
  - `existing-pr` モード: PR の head ブランチを既存ブランチとしてチェックアウトする（新規ブランチは作らない）。
- `${LOG_FILE}` に開始行を 1 行追記する。

# 出力

後続の処理のために次の値を返す。

| 変数 | 内容 |
| --- | --- |
| `MODE` | `new-branch`（通常モード）または `existing-pr`（既存 PR モード） |
| `RUN_DIR` | run ディレクトリの絶対パス（例: `/path/to/repo/.trinity/20260429T153000Z-add-theme-toggle`） |
| `WORKTREE_DIR` | worktree の絶対パス（`${RUN_DIR}/worktree`） |
| `BRANCH` | ブランチ名（`new-branch` モード: `trinity/<TS>-<SLUG>` 形式。`existing-pr` モード: PR の head ブランチ名） |
| `BASE_BRANCH` | base ブランチ名（`new-branch` モード: `DEFAULT_BRANCH` の値（例: `main`）。`existing-pr` モード: PR の base ブランチ名） |
| `PR_NUMBER` | `existing-pr` モードのみ。引数で渡した PR 番号 |
| `PR_URL` | `existing-pr` モードのみ。PR の URL |

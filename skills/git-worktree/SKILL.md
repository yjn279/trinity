---
name: git-worktree
description: "現在の clean なブランチを base として新しいブランチを切り、隔離 worktree を作成する。タイムスタンプ付きの run ディレクトリと trinity.log への開始行追記まで行う。"
when-to-use: "隔離された git worktree が必要なときに使う。呼び出し側から渡すのはスラッグ（kebab-case 2〜5 語）のみ。"
tools: Bash
---

# 役割

隔離 worktree を作成するスキルである。呼び出し側から受けるのはスラッグのみで、リポジトリパス・ログファイルパス・ベースブランチはすべてスキル内部で推測する。タイムスタンプとログ追記まで行い、後続の処理に必要なパスとブランチ名を返す。

# 受け取る入力

- **スラッグ**（kebab-case 2〜5 語、要件から派生）。例: `add-theme-toggle`

これ以外のパラメータ（リポジトリパス、ログファイルパス、ベースブランチ名など）は呼び出し側から受け取らない。

# スキル内で推測する項目

| 項目 | 推測方法 |
| --- | --- |
| リポジトリルート | `git rev-parse --show-toplevel` |
| `BASE_BRANCH` | `git rev-parse --abbrev-ref HEAD`（現在のブランチ） |
| タイムスタンプ | `date -u +%Y%m%dT%H%M%SZ` |
| ログファイルパス | `<リポジトリルート>/.trinity/trinity.log` |
| タイムスタンプ衝突時 | スラッグ末尾に `-2` `-3` … を付けて一意化する |

# ワークフロー

1. **リポジトリルートと BASE_BRANCH を取得する**

   ```shell
   REPO_ROOT=$(git rev-parse --show-toplevel)
   BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
   ```

2. **タイムスタンプと run ディレクトリ名を決定する**

   ```shell
   TS=$(date -u +%Y%m%dT%H%M%SZ)
   SLUG=<呼び出し側から受け取った kebab-case スラッグ>
   RUN_NAME="${TS}-${SLUG}"
   ```

   同一タイムスタンプで衝突（`${REPO_ROOT}/.trinity/${RUN_NAME}` がすでに存在する）した場合は `SLUG` 末尾に `-2` `-3` を付けて一意化する。

3. **パスとブランチ名を確定する**

   ```shell
   RUN_DIR="${REPO_ROOT}/.trinity/${RUN_NAME}"
   WORKTREE_DIR="${RUN_DIR}/worktree"
   BRANCH="trinity/${RUN_NAME}"
   LOG_FILE="${REPO_ROOT}/.trinity/trinity.log"
   ```

4. **run ディレクトリを作成し、worktree をチェックアウトする**

   ```shell
   mkdir -p "${RUN_DIR}"
   git worktree add -b "${BRANCH}" "${WORKTREE_DIR}" "${BASE_BRANCH}"
   ```

5. **trinity.log に開始行を追記する**

   `LOG_FILE` が存在しない場合は作成してから追記する。

   ```shell
   mkdir -p "${REPO_ROOT}/.trinity"
   printf '=== %s run started on %s (base=%s) ===\n' \
     "${RUN_NAME}" "${BRANCH}" "${BASE_BRANCH}" >> "${LOG_FILE}"
   ```

# 副作用

- `${RUN_DIR}/` ディレクトリを新規作成する。
- `git worktree add` で `${WORKTREE_DIR}/` に新ブランチをチェックアウトする。
- `${LOG_FILE}` に開始行を 1 行追記する。

# 出力

後続の処理のために次の値を返す。

| 変数 | 内容 |
| --- | --- |
| `RUN_DIR` | run ディレクトリの絶対パス（例: `/path/to/repo/.trinity/20260429T153000Z-add-theme-toggle`） |
| `WORKTREE_DIR` | worktree の絶対パス（`${RUN_DIR}/worktree`） |
| `BRANCH` | 新規ブランチ名（例: `trinity/20260429T153000Z-add-theme-toggle`） |
| `BASE_BRANCH` | 分岐元ブランチ名（例: `main`） |

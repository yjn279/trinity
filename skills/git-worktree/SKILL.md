---
name: git-worktree
description: "現在の clean なブランチを base として新しいブランチを切り、隔離 worktree を作成する。タイムスタンプ付きの run ディレクトリと trinity.log への開始行追記まで行う。PR_REF が指定された場合は既存 PR の head ブランチをチェックアウトする PR continuation モードで動作する。"
when-to-use: "隔離された git worktree が必要なときに使う。呼び出し側から渡すのはスラッグ（kebab-case 2〜5 語）のみ。PR continuation モードでは追加で PR_REF（PR 番号または PR URL）を渡す。"
tools: Bash
---

# 役割

隔離 worktree を作成するスキルである。呼び出し側から受けるのはスラッグのみ（既定モード）か、スラッグと `PR_REF`（PR continuation モード）である。リポジトリパス・ログファイルパス・ベースブランチはすべてスキル内部で推測する。タイムスタンプとログ追記まで行い、後続の処理に必要なパスとブランチ名を返す。

# 受け取る入力

- **スラッグ**（kebab-case 2〜5 語、要件から派生）。例: `add-theme-toggle`
- **PR_REF**（省略可能）— PR 番号（整数）または PR URL 文字列。省略時は既定モード（新規ブランチ切り出し）で動作する。

これ以外のパラメータ（リポジトリパス、ログファイルパス、ベースブランチ名など）は呼び出し側から受け取らない。

# スキル内で推測する項目

| 項目 | 推測方法 |
| --- | --- |
| リポジトリルート | `git rev-parse --show-toplevel` |
| `BASE_BRANCH`（既定モード） | `git rev-parse --abbrev-ref HEAD`（現在のブランチ） |
| `BASE_BRANCH`（PR continuation） | `gh pr view "$PR_REF" --json baseRefName` の `baseRefName` |
| `BRANCH`（PR continuation） | `gh pr view "$PR_REF" --json headRefName` の `headRefName` |
| タイムスタンプ | `date -u +%Y%m%dT%H%M%SZ` |
| ログファイルパス | `<リポジトリルート>/.trinity/trinity.log` |
| タイムスタンプ衝突時 | スラッグ末尾に `-2` `-3` … を付けて一意化する |

# ワークフロー

## 既定モード（PR_REF なし）

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

## PR continuation モード（PR_REF あり）

1. **リポジトリルートを取得する**

   ```shell
   REPO_ROOT=$(git rev-parse --show-toplevel)
   ```

2. **PR 情報を解決する**

   `PR_REF` が整数の場合も URL の場合も `gh pr view` で統一的に解決する。

   ```shell
   gh pr view "$PR_REF" --json headRefName,baseRefName,url,state,number
   ```

   - `state` が `OPEN` 以外（`CLOSED` / `MERGED`）の場合は処理を停止し、ユーザーに次のメッセージを表示する。
     > PR #<number>（<PR URL>）は <state> 状態です。open な PR のみ指定できます。
   - 解決に失敗した（PR が存在しない等）場合も停止してエラー内容をユーザーに表示する。

   解決成功時に次の値を確定する。

   ```shell
   BRANCH=<headRefName>       # 既存 PR の head ブランチ名（trinity/ プレフィックスとは限らない）
   BASE_BRANCH=<baseRefName>  # 既存 PR の base ブランチ名
   PR_URL=<url>               # 正規化された PR URL
   PR_NUMBER=<number>         # PR 番号（整数）
   ```

3. **タイムスタンプと run ディレクトリ名を決定する**

   `SLUG` は呼び出し側から受け取ったスラッグを使う（PR タイトルからは派生させない）。

   ```shell
   TS=$(date -u +%Y%m%dT%H%M%SZ)
   SLUG=<呼び出し側から受け取った kebab-case スラッグ>
   RUN_NAME="${TS}-${SLUG}"
   ```

   同一タイムスタンプで衝突した場合は `SLUG` 末尾に `-2` `-3` を付けて一意化する。

4. **パスを確定する（BRANCH は PR の headRefName を使う）**

   ```shell
   RUN_DIR="${REPO_ROOT}/.trinity/${RUN_NAME}"
   WORKTREE_DIR="${RUN_DIR}/worktree"
   LOG_FILE="${REPO_ROOT}/.trinity/trinity.log"
   ```

   `BRANCH` は上記ステップ 2 で取得した `headRefName` をそのまま使う（`trinity/<TS>-<SLUG>` 形式にしない）。

5. **PR の head ブランチをローカルにフェッチし、worktree にチェックアウトする**

   新規ブランチを切らず、既存 PR の head ブランチを worktree として展開する。

   ```shell
   mkdir -p "${RUN_DIR}"
   git fetch origin "${BRANCH}:${BRANCH}"
   git worktree add "${WORKTREE_DIR}" "${BRANCH}"
   ```

   - `git fetch origin "${BRANCH}:${BRANCH}"` でリモートの最新状態をローカルに取り込む。
   - `git worktree add "${WORKTREE_DIR}" "${BRANCH}"` で既存ブランチをチェックアウトする（`-b` を使わない点が既定モードと異なる）。

6. **trinity.log に開始行を追記する**

   `LOG_FILE` が存在しない場合は作成してから追記する。

   ```shell
   mkdir -p "${REPO_ROOT}/.trinity"
   printf '=== %s run started on %s (base=%s, pr-continuation=#%s) ===\n' \
     "${RUN_NAME}" "${BRANCH}" "${BASE_BRANCH}" "${PR_NUMBER}" >> "${LOG_FILE}"
   ```

# 副作用

## 既定モード

- `${RUN_DIR}/` ディレクトリを新規作成する。
- `git worktree add -b` で `${WORKTREE_DIR}/` に新ブランチをチェックアウトする。
- `${LOG_FILE}` に開始行を 1 行追記する。

## PR continuation モード

- `${RUN_DIR}/` ディレクトリを新規作成する。
- `git fetch origin` で PR head ブランチの最新コミットをローカルに取り込む。
- `git worktree add`（`-b` なし）で `${WORKTREE_DIR}/` に既存ブランチをチェックアウトする。新規ブランチは作成しない。
- `${LOG_FILE}` に開始行（`pr-continuation=#<PR_NUMBER>` を含む）を 1 行追記する。

# 出力

後続の処理のために次の値を返す。両モードで同じ変数名・意味を持つ。`BRANCH` が `trinity/<TS>-<SLUG>` 形式であるとは限らない（PR continuation モードでは既存 PR の head ブランチ名）。

| 変数 | 内容 |
| --- | --- |
| `RUN_DIR` | run ディレクトリの絶対パス（例: `/path/to/repo/.trinity/20260429T153000Z-add-theme-toggle`） |
| `WORKTREE_DIR` | worktree の絶対パス（`${RUN_DIR}/worktree`） |
| `BRANCH` | worktree が指すブランチ名。既定モードでは `trinity/<TS>-<SLUG>` 形式。PR continuation モードでは PR の `headRefName`（任意の命名）。 |
| `BASE_BRANCH` | 分岐元ブランチ名。既定モードでは現在のブランチ、PR continuation モードでは PR の `baseRefName`。 |

---
name: git-worktree
description: 既存ブランチから派生した新規ブランチを隔離 git worktree として展開する。呼び出し側から要件文（または slug ヒント）・base ref・リポジトリルートを受け取り、タイムスタンプ・slug・ブランチ名・RUN_DIR・WORKTREE_PATH をスキル内で組み立てて `git worktree add` で安全にセットアップする。worktree の上書き防止、絶対パス強制、隔離原則を規定する。
---

# git-worktree

要件文から slug とタイムスタンプを組み立て、ブランチを隔離 worktree として展開する。組み立てロジックはすべてスキル内で完結する。呼び出し側は最小限の情報を渡すだけでよい。

## 入力契約

呼び出し側から次を受け取る。`SLUG` / `TS` / `BRANCH_NAME` / `WORKTREE_PATH` / `RUN_DIR` は呼び出し側から受け取らない。これらはすべてスキル内で組み立てる。

- `REQUIREMENT` または `SLUG_HINT` — slug 生成のための要件文（または既に組み立てた slug ヒント）
- `BASE_REF` — worktree が派生するブランチ / コミット
- `REPO_ROOT` — slug 衝突確認用に、起動側リポジトリの絶対パス
- `LOG_PATH`（任意） — 開始行を追記するログファイルの絶対パス

## スキル内での変数組み立て

呼び出し側から受け取った情報をもとに、次を組み立てる。

```shell
TS=$(date -u +%Y%m%dT%H%M%SZ)
SLUG=<REQUIREMENT から英字 kebab-case 2〜5 語、ASCII のみ、「動詞 + 目的語」形が望ましい>
RUN_DIR="${REPO_ROOT}/.trinity/${TS}-${SLUG}"
WORKTREE_PATH="${RUN_DIR}/worktree"
BRANCH_NAME="trinity/${TS}-${SLUG}"
```

`SLUG` は `SLUG_HINT` が渡された場合はそれをそのまま使う。`REQUIREMENT` が渡された場合は要件文から英字 kebab-case の 2〜5 語を抽出する（例: `add-theme-toggle`）。

### slug 衝突処理

組み立てた `RUN_DIR` と同名のディレクトリが既に `REPO_ROOT/.trinity/` に存在する場合、末尾に `-2` `-3` ... を付けて衝突しないものを採用する。

```shell
# 衝突確認の例
if [ -d "$RUN_DIR" ]; then
  i=2
  while [ -d "${REPO_ROOT}/.trinity/${TS}-${SLUG}-${i}" ]; do
    i=$((i + 1))
  done
  SLUG="${SLUG}-${i}"
  RUN_DIR="${REPO_ROOT}/.trinity/${TS}-${SLUG}"
  WORKTREE_PATH="${RUN_DIR}/worktree"
  BRANCH_NAME="trinity/${TS}-${SLUG}"
fi
```

## セットアップ手順

```shell
mkdir -p "$RUN_DIR"
git -C "$REPO_ROOT" worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "$BASE_REF"
```

`WORKTREE_PATH` はスキル内で組み立てた絶対パスをそのまま使う。`pwd` を混ぜない。

`LOG_PATH` が渡された場合のみ、次の形式で開始行を追記する。

```shell
printf '=== %s started (branch=%s, base=%s) ===\n' \
  "$(basename "$WORKTREE_PATH")" "$BRANCH_NAME" "$BASE_REF" >> "$LOG_PATH"
```

`LOG_PATH` が渡されなければログ追記を行わない。

## 前提確認

- `WORKTREE_PATH` が既存ディレクトリであれば展開せずに停止し、衝突処理の再実行を促す
- `BASE_REF` が有効なブランチ / コミットかどうかは `git -C "$REPO_ROOT" rev-parse --verify "$BASE_REF"` で確認する

## 戻り値

次の値を呼び出し側へ返す。

- `TS` — 組み立てたタイムスタンプ
- `SLUG` — 確定した slug（衝突回避済み）
- `BRANCH_NAME` — `trinity/<TS>-<SLUG>` 形式のブランチ名
- `RUN_DIR` — `<REPO_ROOT>/.trinity/<TS>-<SLUG>` の絶対パス
- `WORKTREE_PATH` — `<RUN_DIR>/worktree` の絶対パス

## やってはいけないこと

- `cd` してから `git worktree add` を打たない（必ず `git -C "$REPO_ROOT"` か絶対パスで操作する）
- `WORKTREE_PATH` が既存の場合に上書きしない（衝突処理を経て新しい suffix を付ける）
- `BASE_REF` 上に直接 worktree を作らない（`BRANCH_NAME` を新規作成して隔離する）
- 相対パスを混ぜない（Bash 呼び出し間で cwd が引き継がれないため必ず絶対パスを使う）
- slug 生成やタイムスタンプの組み立てを呼び出し側に委ねない（スキル内の責務）

---
name: git-isolated-worktree
description: 既存ブランチから派生した新規ブランチを隔離 git worktree として展開する。呼び出し側から branch 名・展開先パス・base ref を受け取り、`git worktree add` で安全にセットアップする。worktree の上書き防止、絶対パス強制、隔離原則を規定する。
---

# git-isolated-worktree

ブランチを隔離 worktree として展開する。呼び出し側がパラメータを名前付きで提示し、本スキルがセットアップを実行する。

## 入力契約

呼び出し側から次を受け取る。

- `BASE_REF` — worktree が派生するブランチ / コミット
- `BRANCH_NAME` — 新規作成するブランチ名
- `WORKTREE_PATH` — worktree を展開する絶対パス
- `LOG_PATH`（任意） — 開始行を追記する任意のログファイルの絶対パス

## セットアップ手順

```shell
git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "$BASE_REF"
```

`WORKTREE_PATH` は呼び出し側が組み立てた絶対パスをそのまま使う。`pwd` を混ぜない。

`LOG_PATH` が渡された場合のみ、次の形式で開始行を追記する。

```shell
printf '=== %s started (branch=%s, base=%s) ===\n' \
  "$(basename "$WORKTREE_PATH")" "$BRANCH_NAME" "$BASE_REF" >> "$LOG_PATH"
```

`LOG_PATH` が渡されなければログ追記を行わない。

## 前提確認

- `WORKTREE_PATH` が既存ディレクトリであれば展開せずに停止し、呼び出し側にパスの再決定を促す
- `BASE_REF` が有効なブランチ / コミットかどうかは `git rev-parse --verify "$BASE_REF"` で確認する

## やってはいけないこと

- `cd` してから `git worktree add` を打たない（必ず `git -C` か絶対パスで操作する）
- `WORKTREE_PATH` が既存の場合に上書きしない（呼び出し側が suffix を付けて再試行する）
- `BASE_REF` 上に直接 worktree を作らない（`BRANCH_NAME` を新規作成して隔離する）
- 相対パスを混ぜない（Bash 呼び出し間で cwd が引き継がれないため必ず絶対パスを使う）
- slug 生成やタイムスタンプの組み立てを本スキル内で行わない（呼び出し側の責務）

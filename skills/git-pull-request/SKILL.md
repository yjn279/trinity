---
name: git-pull-request
description: "Generator がコミットを積んだ worktree のブランチを origin に push し、PR を作成する。push が既存リモートブランチを上書きしないことを保証する。PR continuation モードでは push のみ行い、新規 PR は作成しない。"
when-to-use: "worktree ブランチの push と PR 作成が必要なときに使う。既定モードでは PR タイトルと PR 本文のみを渡す。PR continuation モードでは追加で MODE=pr-continuation と既存 PR URL を渡す。"
tools: Bash
---

# 役割

worktree のブランチを `origin` に push し、Pull Request を作成するスキルである。push の衝突防止を含み、worktree パスとベースブランチはスキル内部で推測する。

- **既定モード（MODE=default）**: PR タイトルと PR 本文のみ渡す。push 後に `gh pr create` で新規 PR を作成し、`PR_NUMBER` / `PR_URL` を返す。
- **PR continuation モード（MODE=pr-continuation）**: PR タイトル・PR 本文に加え、`MODE=pr-continuation` と `EXISTING_PR_URL`（既存 PR の URL）を渡す。push のみ行い、新規 PR は作成しない。`PR_URL` は渡された既存 PR URL をそのまま返す。

# 受け取る入力

## 既定モード（MODE=default またはMODE省略）

- **PR タイトル**（文字列）
- **PR 本文**（文字列）

## PR continuation モード（MODE=pr-continuation）

- **PR タイトル**（文字列）— 内部での区別用。push のみのため PR 作成には使わない。
- **PR 本文**（文字列）— 内部での区別用。push のみのため PR 作成には使わない。
- **MODE**（文字列）— `pr-continuation` 固定
- **EXISTING_PR_URL**（文字列）— 既存 PR の URL。出力でそのまま返す。

これ以外のパラメータ（worktree パス、ブランチ名、ベースブランチ名、リポジトリ情報など）は呼び出し側から受け取らない。

PR 本文の組み立て（plan.md の目的・受け入れ基準の引用、eval レポートの判定セクションの引用など）は呼び出し側の責任で行い、完成した文字列としてこのスキルに渡す。

# スキル内で推測する項目

| 項目 | 推測方法 |
| --- | --- |
| worktree パス | `git worktree list --porcelain` から現在の作業ブランチに紐づく非メイン worktree を選択する |
| ブランチ名 | 上記 worktree の `branch` フィールド（HEAD ref） |
| ベースブランチ | `git merge-base --fork-point <known-base> HEAD` または reflog から、worktree のブランチが分岐した親ブランチを推測する。複数候補になる場合のみユーザーに選択肢を提示する |
| リモート owner/repo | `git -C "$WORKTREE_DIR" remote get-url origin` からパースする |

# ワークフロー

## 既定モード（MODE=default またはMODE省略）

### 1. worktree と作業ブランチを特定する

`git worktree list --porcelain` の出力を解析し、現在進行中の作業が含まれる非メイン worktree を選択する。

```shell
git worktree list --porcelain
```

`WORKTREE_DIR` と `BRANCH` を確定する。

注意: PR continuation モードでは `BRANCH` が `trinity/` で始まらない場合がある（既存 PR の head ブランチ名）。このステップでブランチ名の prefix 形式に依存したフィルタリングは行わず、現在アクティブな非メイン worktree を選択する。

### 2. ベースブランチを推測する

```shell
git -C "$WORKTREE_DIR" log --oneline --decorate | head -20
git -C "$WORKTREE_DIR" for-each-ref --format='%(refname:short)' refs/heads/ | grep -v "^trinity/"
```

reflog とブランチ一覧から、このブランチが切り出された元ブランチ（通常 `main` または `master`）を推測する。候補が一意に決まらない場合のみユーザーに確認する。

### 3. リモート同名ブランチの存在を確認する（push 上書き防止）

push の前に `git ls-remote --heads origin <branch>` でリモート同名ブランチの存在を確認する。

```shell
git -C "$WORKTREE_DIR" ls-remote --heads origin "$BRANCH"
```

- **リモートにブランチが存在しない場合**: 通常通り push を進める。
- **リモートにブランチが存在する場合**: push を中断し、ユーザーに次のメッセージを通知して停止する。
  > `origin/<branch>` がすでに存在します。上書き push は行いません。リモートブランチを手動で確認・削除した後、再度実行してください。

ブランチ命名に秒精度のタイムスタンプが含まれる場合でも、命名規約に頼らずこのチェックを必ず実施する。

### 4. push する（ネットワーク要因の再試行付き）

```shell
git -C "$WORKTREE_DIR" push -u origin "$BRANCH"
```

失敗がネットワーク要因（exit code による判定）のときのみ、最大 4 回 exponential backoff で再試行する（2s、4s、8s、16s）。権限エラー・ブランチ保護など、ネットワーク以外の原因による失敗はそのまま停止してユーザーに報告する。

### 5. PR を作成する

リモート URL から owner/repo を取得し、`gh pr create` で PR を作成する。

```shell
gh pr create \
  --title "$PR_TITLE" \
  --body "$PR_BODY" \
  --base "$BASE_BRANCH" \
  --head "$BRANCH"
```

`gh` が利用できない環境では `mcp__github__create_pull_request` ツールで代替する。

## PR continuation モード（MODE=pr-continuation）

### 1. worktree と作業ブランチを特定する

既定モードのステップ 1 と同じ手順で `WORKTREE_DIR` と `BRANCH` を確定する。`BRANCH` が `trinity/` で始まらない点を考慮し、worktree 一覧から現在アクティブな非メイン worktree をブランチ prefix に依存せずに選択する。

### 2. リモート同名ブランチ確認ステップは実施しない

既定モードのステップ 3（`git ls-remote --heads origin "$BRANCH"` でリモート同名ブランチが存在する場合に push を中断する）は、PR continuation モードでは実施しない。

理由: 既存 PR に紐づくブランチはリモートに必ず存在する（PR 自体がリモートブランチを前提として成立している）。このため、リモート同名ブランチの存在を理由とした中断は「既存 PR への追加 push」という意図的な操作を誤って防ぐことになり、不要なチェックとなる。衝突の検出は後続のステップ 3（fast-forward チェック）で代替する。

### 3. リモートへの追加 push が fast-forward であることを確認する

push の前に、ローカルの `BRANCH` がリモートの `origin/<BRANCH>` より先にある（fast-forward な関係）かを確認する。

```shell
git -C "$WORKTREE_DIR" fetch origin "$BRANCH"
git -C "$WORKTREE_DIR" log --oneline "origin/${BRANCH}..HEAD"
```

- **ローカルがリモートより進んでいる（fast-forward）**: push を進める。
- **リモートがローカルより進んでいる、または diverged（fast-forward でない）**: push を中断し、ユーザーに次のメッセージを通知して停止する。force push は行わない。
  > `origin/<branch>` がローカルより先に進んでいます（または diverged）。fast-forward でない push は行いません。`git pull --rebase` 等でローカルを最新化してから再度実行してください。

### 4. 追加 push する（ネットワーク要因の再試行付き）

```shell
git -C "$WORKTREE_DIR" push origin "$BRANCH"
```

既定モードとは異なり、`-u` フラグは省略可（上流追跡は既存 PR の段階で設定済みのため）。失敗がネットワーク要因のときのみ、最大 4 回 exponential backoff で再試行する。ネットワーク以外の原因による失敗はそのまま停止してユーザーに報告する。

### 5. 新規 PR は作成しない

PR continuation モードでは `gh pr create` を呼ばない。`PR_URL` は呼び出し側から渡された `EXISTING_PR_URL` をそのまま返す。

# 副作用

## 既定モード

- `git push -u origin <branch>` を実行し、リモートにブランチを作成する。
- `gh pr create` または `mcp__github__create_pull_request` で PR を作成する。

## PR continuation モード

- `git fetch origin <branch>` でリモートの最新状態を確認する。
- fast-forward の場合のみ `git push origin <branch>` を実行し、既存 PR に追加コミットを反映する。
- `gh pr create` は呼ばない。既存 PR の URL はそのまま保持する。

# 出力

| 項目 | 内容 |
| --- | --- |
| PR URL | 既定モード: 作成された PR の URL。PR continuation モード: 渡された既存 PR URL をそのまま返す。 |
| push 結果 | push 成功 / 失敗 / 中断（既定モード: リモート同名ブランチ存在。PR continuation モード: fast-forward でない） |

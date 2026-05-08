---
name: git-pull-request
description: worktree 上のブランチを origin に push し、続けて同一スキル内で Pull Request を作成する。push 前の既存ブランチ確認、ネットワーク障害に対する指数バックオフ再試行、恒久失敗の即停止、push 成功直後の PR 作成、`PR_NUMBER` / `PR_URL` の返却を規定する。PR タイトル / 本文 / owner / repo の取り出しもスキル内で完結させる。
---

# git-pull-request

ブランチを origin に push し、push 成功直後に PR を作成する。push と PR 作成は一連の作業フローとして 1 スキルで完結させる。PR タイトル / 本文 / `OWNER` / `REPO` は呼び出し側から受け取らない。スキル内で組み立てる。

## 入力契約

呼び出し側から次を受け取る。`PR_TITLE` / `PR_BODY` / `OWNER` / `REPO` は呼び出し側から受け取らない。これらはすべてスキル内で組み立てる。

- `WORKTREE_DIR` — push 元の worktree の絶対パス
- `BRANCH` — push 対象のブランチ名
- `BASE_BRANCH` — PR の base ブランチ
- `PLAN_PATH` — `plan.md` の絶対パス（PR タイトル / 本文を組み立てるため）
- `EVAL_PATH` — 最終 Evaluator レポートの絶対パス（同上）
- `RUN_META` — 任意の小さなメタ情報（イテレーション番号、最終コミット SHA、`RUN_DIR` のリポジトリルートからの相対表記）

## push 前の既存ブランチ確認

push を実行する**前に**、同名のリモートブランチが既に存在しないことを確認する。

```shell
git -C "$WORKTREE_DIR" ls-remote --heads origin "$BRANCH"
```

このコマンドが 1 行以上を出力した場合、同名のリモートブランチが存在する。**push せず即停止**し、次の情報を呼び出し側に返す。

- 競合しているブランチ名
- 既存 PR の有無（`gh pr list --head "$BRANCH" --repo <owner>/<repo>` の結果）
- 原因として考えられる経路（同 slug の再実行、suffix 競合の取りこぼしなど）

コマンドが 0 行（存在しない）を返した場合のみ push に進む。

## push

```shell
git -C "$WORKTREE_DIR" push -u origin "$BRANCH"
```

### 再試行する失敗

次のいずれかが stderr に現れた場合のみ再試行する。

- `Could not resolve host`
- `Connection timed out` / `Connection refused`
- `Operation timed out`
- `error: RPC failed`（HTTP 5xx 系を含む）
- `fatal: unable to access` の中で 503 / 504 / network 系メッセージを含むもの
- `gnutls_handshake() failed` などの一時的な TLS エラー

最大 4 回まで再試行し、合計で最大 5 回試行する。

| 失敗回 | 次の試行までの待機 |
| --- | --- |
| 1 回目失敗 | 2 秒 |
| 2 回目失敗 | 4 秒 |
| 3 回目失敗 | 8 秒 |
| 4 回目失敗 | 16 秒 |
| 5 回目失敗 | 停止して報告 |

### 即停止する失敗

次は再試行せず、即座に停止して呼び出し側に報告する。

- `Permission denied` / `403`
- `protected branch` / `branch protection`
- `pre-receive hook declined`
- `non-fast-forward`（ローカルが古い）
- `does not appear to be a git repository`
- `remote rejected`
- 認証情報の不足（`Authentication failed` など）

stderr の原文を最低 5 行そのまま見せ、何が起きたか・どこを見るべきかを 2〜3 文で添える。

エラー文字列の判定は完全一致ではなく substring マッチで行う（`grep -i` 相当）。恒久的失敗を示すメッセージが 1 つでもあれば即停止に倒す。迷ったら**停止側に倒す**。

### やってはいけないこと（push）

- push 前の既存ブランチ確認を省略しない
- `--force` / `--force-with-lease` を使わない（新規ブランチへの push のみで上書きは不要）
- `--no-verify` で hooks をスキップしない
- 再試行回数を変えない（2/4/8/16 秒・最大 4 回再試行・合計 5 回で固定）

## PR 作成

push 成功直後に同一スキル内で PR を作成する。

### owner / repo の取り出し

```shell
git -C "$WORKTREE_DIR" remote get-url origin
```

`https://github.com/<owner>/<repo>.git` または `git@github.com:<owner>/<repo>.git` のどちらにも対応する。末尾の `.git` は剥がす。

### PR タイトルの組み立て

`PLAN_PATH` の先頭 H1 本文を取り出す。70 文字超なら冒頭 70 文字で切り詰める。H1 が無ければ `BRANCH` 名をフォールバックとして使う。

### PR 本文の組み立て

次のテンプレで組み立てる。

```markdown
## 概要
<PLAN_PATH の `## 背景` セクション本文>

## ゴール
<PLAN_PATH の `## ゴール` セクション>

## 受け入れ基準
<PLAN_PATH の `## 受け入れ基準（Evaluator用チェックリスト）` セクション>

## Trinity 実行サマリ
<RUN_META の内容>

## 判定根拠（最終 Evaluator レポートからの抜粋）
<EVAL_PATH の `## 軸別スコア` セクション>
```

該当セクションが無い場合はその節を省く（空 H2 を残さない）。`## 軸別スコア` が無ければ `## 受け入れ基準` 節を代用する。

### PR の作成

`mcp__github__create_pull_request` を使う。スキーマが未ロードなら呼ぶ前に読み込む。

```
ToolSearch query="select:mcp__github__create_pull_request"
```

- `owner` / `repo` — 上で取り出した値
- `title` — 上で組み立てた PR タイトル
- `body` — 上で組み立てた PR 本文
- `base` — `BASE_BRANCH`
- `head` — `BRANCH`

### 戻り値

PR 作成レスポンスから次の 2 値を取り出して呼び出し側へ返す。

- `PR_NUMBER` — マージ確認と `mcp__github__merge_pull_request` 呼び出しに使う
- `PR_URL` — 最終出力と否認時のユーザーへの提示に使う

### やってはいけないこと（PR）

- PR タイトル / 本文 / `OWNER` / `REPO` を呼び出し側から受け取らない（スキル内の責務）
- PR の base を `BRANCH` 自身や固定値にしない（必ず `$BASE_BRANCH` を使う）
- push が失敗しているのに PR 作成に進まない

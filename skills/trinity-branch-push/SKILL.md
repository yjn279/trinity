---
name: trinity-branch-push
description: Trinity の最終化フェーズで、隔離 worktree 上のブランチを origin に push するときの再試行規約を提供する。Evaluator が PASS を返した直後、PR 作成（`trinity-pr-from-artifacts`）の前に参照する。push 前に同名のリモートブランチが存在しないことを確認し、存在した場合は即停止する。ネットワーク由来の一時失敗のみ指数バックオフ（2s, 4s, 8s, 16s、最大 4 回）で再試行し、権限・ブランチ保護・上流拒否などの恒久的失敗は即停止してユーザーに報告する。一時失敗と恒久失敗の見分け方を含む。
---

# trinity-branch-push

最終 PASS 後に worktree のブランチを origin に push する。push の失敗を闇雲に再試行すると、権限不足やブランチ保護の問題が無駄なリトライで埋もれてしまう。本スキルはネットワーク由来の一時失敗のみ exponential backoff で再試行する規約を持つ。

## push 前の既存ブランチ確認

push を実行する**前に**、同名のリモートブランチが既に存在しないことを確認する。

```shell
git -C "$WORKTREE_DIR" ls-remote --heads origin "$BRANCH"
```

このコマンドが 1 行以上を出力した場合、同名のリモートブランチが存在する。**push せず即停止**し、ユーザーに次の情報を見せる。

- 競合しているブランチ名
- 既存 PR の有無（`gh pr list --head "$BRANCH" --repo <owner>/<repo>` の結果）
- 原因として考えられる経路（同 slug の再実行、suffix 競合の取りこぼしなど）

既存ブランチが存在するかどうかを Trinity が自動で解決することはしない。ユーザーが既存ブランチと PR の状態を確認し、不要なら削除してから再実行するよう案内する。

コマンドが 0 行（存在しない）を返した場合のみ push に進む。

## 基本コマンド

```shell
git -C "$WORKTREE_DIR" push -u origin "$BRANCH"
```

`$WORKTREE_DIR` は隔離 worktree の絶対パス、`$BRANCH` は `trinity/<TS>-<slug>` 形式のブランチ名（`trinity-rundir-worktree` で確定したもの）。

## 再試行する失敗

次のいずれかが stderr に現れた、もしくは exit code がそれを示している場合のみ再試行する。

- `Could not resolve host`
- `Connection timed out` / `Connection refused`
- `Operation timed out`
- `error: RPC failed`（HTTP 5xx 系を含む）
- `fatal: unable to access` の中で 503 / 504 / network 系メッセージを含むもの
- `gnutls_handshake() failed` などの一時的な TLS エラー

これらに該当した場合、次の表に従って再試行する。最大 4 回まで再試行し、合計で最大 5 回試行する。

| 失敗回 | 次の試行までの待機 |
| --- | --- |
| 1 回目失敗 | 2 秒 |
| 2 回目失敗 | 4 秒 |
| 3 回目失敗 | 8 秒 |
| 4 回目失敗 | 16 秒 |
| 5 回目失敗 | 停止して報告 |

これ以上は粘らない（合計 30 秒待った時点で諦める）。

## 即停止する失敗

次は再試行せず、即座に停止してユーザーに報告する。再試行で状況が変わらない問題だからである。

- `Permission denied` / `403`
- `protected branch` / `branch protection`
- `pre-receive hook declined`
- `non-fast-forward`（ローカルが古い）
- `does not appear to be a git repository`
- `remote rejected`
- 認証情報の不足（`Authentication failed` など）

これらに該当する場合、stderr の原文を最低 5 行はそのままユーザーに見せ、何が起きたか・どこを見るべきかを 2〜3 文で添える。Trinity の責務はここまでで、解決はユーザーに委ねる。

## 判別の指針

エラー文字列の判定は完全一致ではなく substring マッチで行う。`grep -i` 相当の case-insensitive で見る。stderr に複数のメッセージが出ている場合、恒久的失敗を示すメッセージが 1 つでもあれば即停止に倒す。再試行可能と恒久的の両方が混在することは事実上ないが、迷ったら**停止側に倒す**のが安全である。再試行は副作用がない場合に限り正当化される。

## 成功時

push が成功したら、push 結果（短縮 SHA と上流ブランチ名）を保持して `trinity-pr-from-artifacts` に渡す。本スキルは PR を作らない。push と PR 作成は責務を分けてある。

## やってはいけないこと

- push 前の既存ブランチ確認を省略しない（`ls-remote` で必ず事前確認する）
- 既存リモートブランチが存在するのに push に進まない（即停止する）
- `--force` / `--force-with-lease` を使わない（Trinity は新規ブランチに push するだけで、上書きの必要が一切ない）
- `--no-verify` で hooks をスキップしない
- 失敗を握りつぶしてループを継続しない（PASS 後の push 失敗は明確にエラー）
- 再試行回数を実装ごとに変えない（2,4,8,16 秒・再試行 最大 4 回・合計 5 回試行で固定）

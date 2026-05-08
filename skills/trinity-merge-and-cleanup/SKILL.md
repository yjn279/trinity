---
name: trinity-merge-and-cleanup
description: Trinity の PR 作成直後に「マージしてお片付けまで進めるか」をユーザーに確認し、承認時のみ squash マージ・リモートブランチ削除・worktree 削除・ローカルブランチ削除・`.trinity/<run>/` 削除までを実行する。`trinity-pr-from-artifacts` で PR 作成と PR 番号/URL の取得が終わった直後に必ず参照する。`AskUserQuestion` は最大 2 回（マージ確認 1 回 + 否認時のヒアリング 1 回）。マージ失敗時の停止規約、お片付けの順序とフォールバックを規定する。
---

# trinity-merge-and-cleanup

Trinity の最終化は「PR を作るだけ」では完結しない。レビュー不要の自動運転タスクではユーザーがマージとお片付けまで一気に進めたい一方、追加の改善が必要なタスクでは PR を残して次のインプットをヒアリングしたい。本スキルはこの分岐をユーザーに 1 回だけ問い、承認時にマージとお片付けまで実行する。否認時は改善項目をヒアリングする。

## 前提

`trinity-pr-from-artifacts` の完了直後で、次が確定している。

- `PR_NUMBER` — 新しく作られた PR の番号
- `PR_URL` — PR の URL
- `BRANCH` — `trinity/<TS>-<slug>`
- `WORKTREE_DIR` — `${RUN_DIR}/worktree` の絶対パス
- `RUN_DIR` — `.trinity/<TS>-<slug>` の絶対パス
- 起動側リポジトリのリポジトリルート（オーケストレーターが `pwd` で取れる）

## マージ確認

PR 作成直後、ユーザーへの最終出力より前に `AskUserQuestion` を 1 回目として呼ぶ。`AskUserQuestion` の合計呼び出し回数は最大 2 回（マージ確認 1 回 + 否認時のヒアリング 1 回）に限定する。「マージしてお片付け」を選んだ場合は 1 回で終わる。

- 質問: `PR #<PR_NUMBER> (<PR_URL>) を作成しました。マージしてお片付けまで進めますか？`
- 選択肢:
  1. `マージしてお片付け (Recommended)` — リモートで PR をマージし、ローカル worktree と branch と `.trinity/<run>/` を削除する
  2. `PR は残して改善項目を相談する` — マージとお片付けをせず、追加で改善項目をヒアリングする

`Other`（自由入力）は `AskUserQuestion` が自動で付与する。`Other` の回答が「マージしてお片付け」と明確に解釈できる場合は 1 番目扱い。それ以外は 2 番目扱いとし、ヒアリングを続ける。判定に迷ったら 2 番目（ヒアリング側）に倒す。

## マージ実行（承認時のみ）

`mcp__github__merge_pull_request` を使う。スキーマが未ロードなら呼ぶ前に読み込む。

```
ToolSearch query="select:mcp__github__merge_pull_request"
```

owner / repo / PR 番号は `trinity-pr-from-artifacts` で取得した値を引き継ぐ。マージ方式は `squash` に固定する。

マージ失敗（コンフリクト、ブランチ保護違反、必須レビュー未完了、CI 失敗待ちなど）は**再試行せずに停止**し、エラー文言と `PR_URL` をユーザーに伝える。お片付けには進まない。マージ失敗の理由は GitHub の API が返す `message` をそのまま見せる。Trinity 側で意訳しない。

## お片付け（マージ成功時のみ）

次の手順を順に実行する。1 ステップが失敗した場合は以下のフォールバックで Trinity が完結させる。すべてのフォールバックでも失敗した場合に限り、その特定のステップのみをユーザーに伝える。

### 1. リモートブランチの削除とローカル fetch

GitHub の PR マージで自動削除されない場合に備えて、明示的に削除する。

```shell
git -C "$WORKTREE_DIR" push origin --delete "$BRANCH"
```

このコマンドの失敗は致命的ではない（既に削除済みなら `remote ref does not exist` で返る）。stderr が「既に削除済み」を示す場合は成功扱いにし、それ以外は失敗扱い。失敗した場合は次のフォールバックで再試行する。

```shell
gh api -X DELETE "repos/<owner>/<repo>/git/refs/heads/$BRANCH"
```

その後、起動側リポジトリのリモート追跡参照を更新する。

```shell
git -C "$(pwd)" fetch --prune origin
```

### 2. worktree の削除

worktree ディレクトリを削除する。

```shell
git -C "$(pwd)" worktree remove "$WORKTREE_DIR"
```

`worktree remove` は worktree が dirty（未コミットの変更がある）だと失敗する。Trinity の流儀では Generator が単一コミットで終えているので通常は clean だが、念のため `--force` 付きで再試行する。

```shell
git -C "$(pwd)" worktree remove --force "$WORKTREE_DIR"
```

それでも失敗した場合は `rm -rf` と `worktree prune` で完結させる。

```shell
rm -rf "$WORKTREE_DIR" && git -C "$(pwd)" worktree prune
```

### 3. ローカルブランチの削除

```shell
git -C "$(pwd)" branch -D "$BRANCH"
```

Trinity の流儀では起動側リポジトリ自身がこのブランチを使っていることはない（`BASE_BRANCH` 上で起動するため）。`-D` で安全に消せる。失敗した場合は次のフォールバックで完結させる。

```shell
git -C "$(pwd)" update-ref -d "refs/heads/$BRANCH"
```

### 4. `.trinity/<run>/` の削除

run ディレクトリ全体（`plan.md` `eval-*.md` `worktree/` を含む）を削除する。

```shell
rm -rf "$RUN_DIR"
```

`.trinity/trinity.log`（リポジトリ全体の通算ログ）は `RUN_DIR` 外にあるため削除しない。

## 否認時のヒアリング

ユーザーが「PR は残して改善項目を相談する」を選んだ場合、または `Other` が 2 番目扱いになった場合、マージとお片付けは行わない。代わりに `AskUserQuestion` を 2 回目として 1 回だけ呼び、改善項目をヒアリングする。

- 質問: `改善したい内容を教えてください。次の /trinity:run のインプットとして使います。`
- 選択肢: なし（自由入力）

ユーザーの回答を受け取ったら、最終出力の末尾に次の行を加える。

```
Followup: <ユーザーの回答をそのまま引用>
```

これ以上 `AskUserQuestion` を呼ばない。次の `/trinity:run` への自動投入は行わない。ユーザーが `Followup:` の内容を次回の要件として手動で使う。

## 受け渡し

このスキルが返す情報は次のとおり。最終出力に組み込む。

- `MERGE_RESULT` ∈ { `merged`, `declined`, `failed: <理由>` }
- `CLEANUP_RESULT` ∈ { `done`, `skipped`, `partial: <残っている操作>` }

最終出力フォーマットの組み立ては本スキルの責務外。`/trinity:run` コマンドのテンプレに値を流し込む。

## やってはいけないこと

- `AskUserQuestion` を 3 回以上呼ぶ（合計最大 2 回まで）
- マージ失敗を再試行する（コンフリクトもブランチ保護違反も再試行で解決しない）
- マージ方式を `merge` や `rebase` にする（`squash` で固定）
- `worktree remove --force` を最初から打つ（dirty を握りつぶすので、まず非 force で試す）
- お片付けの各ステップで即座にユーザーに投げる（フォールバックを試してから報告する）
- 否認時にマージやお片付けを勝手に実行する

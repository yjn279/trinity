---
name: trinity-merge-and-cleanup
description: Trinity の PR 作成直後に「マージしてお片付けまで進めるか」をユーザーに確認し、承認時のみ squash マージ・リモートブランチ削除・worktree 削除・ローカルブランチ削除までを実行する。`trinity-pr-from-artifacts` で PR 作成と PR 番号/URL の取得が終わった直後に必ず参照する。`AskUserQuestion` の選択肢、否認時に残っている操作のユーザーへの提示、マージ失敗時の停止規約、お片付けの順序とフォールバック（`worktree remove --force`）を規定する。
---

# trinity-merge-and-cleanup

Trinity の最終化は「PR を作るだけ」では完結しない。レビュー不要の自動運転タスクではユーザーがマージとお片付けまで一気に進めたい一方、レビューを挟みたいタスクでは PR を残しておきたい。本スキルはこの分岐をユーザーに 1 回だけ問い、承認時にマージとお片付けまで実行する。

## 前提

`trinity-pr-from-artifacts` の完了直後で、次が確定している。

- `PR_NUMBER` — 新しく作られた PR の番号
- `PR_URL` — PR の URL
- `BRANCH` — `trinity/<TS>-<slug>`
- `WORKTREE_DIR` — `${RUN_DIR}/worktree` の絶対パス
- 起動側リポジトリのリポジトリルート（オーケストレーターが `pwd` で取れる）

## マージ確認

PR 作成直後、ユーザーへの最終出力より前に `AskUserQuestion` を 1 回だけ呼ぶ。複数回呼ばない（注意力を浪費する）。

- 質問: `PR #<PR_NUMBER> (<PR_URL>) を作成しました。マージしてお片付けまで進めますか？`
- 選択肢:
  1. `マージしてお片付け (Recommended)` — リモートで PR をマージし、ローカル worktree と branch を削除する
  2. `PR は残す（マージしない）` — マージもお片付けもしない。ユーザーが後で手動で扱う

`Other`（自由入力）は `AskUserQuestion` が自動で付与する。`Other` の回答が「マージしてお片付け」と明確に解釈できない場合は **「PR は残す」として扱う**（フェイルセーフ側）。判定に迷ったら停止せずに「PR は残す」に倒す。

回答が「マージしてお片付け」のときだけ、以下のマージ実行とお片付けに進む。それ以外（否認・解釈不能な Other）はどちらも行わない。

## マージ実行（承認時のみ）

`mcp__github__merge_pull_request` を使う。スキーマが未ロードなら呼ぶ前に読み込む。

```
ToolSearch query="select:mcp__github__merge_pull_request"
```

owner / repo / PR 番号は `trinity-pr-from-artifacts` で取得した値を引き継ぐ。マージ方式は `squash` に固定する。

マージ失敗（コンフリクト、ブランチ保護違反、必須レビュー未完了、CI 失敗待ちなど）は**再試行せずに停止**し、エラー文言と `PR_URL` をユーザーに伝える。お片付けには進まない。マージ失敗の理由は GitHub の API が返す `message` をそのまま見せる。Trinity 側で意訳しない。

## お片付け（マージ成功時のみ）

次の手順を順に実行する。1 ステップが失敗したら以降をスキップし、未実行の操作を「次イテレーションで実行すべき手動コマンド」としてユーザーに伝える。`Cleanup:` 行に `partial: <残っている操作>` を出す。

### 1. リモートブランチの削除とローカル fetch

GitHub の PR マージで自動削除されない場合に備えて、明示的に削除する。

```shell
git -C "$WORKTREE_DIR" push origin --delete "$BRANCH"
```

このコマンドの失敗は致命的ではない（既に削除済みなら `remote ref does not exist` で返る）。stderr が「既に削除済み」を示す場合は成功扱いにし、それ以外は失敗扱い。

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

それでも失敗したらここで停止し、未実行の `branch -D` をユーザーに提示する。

### 3. ローカルブランチの削除

```shell
git -C "$(pwd)" branch -D "$BRANCH"
```

Trinity の流儀では起動側リポジトリ自身がこのブランチを使っていることはない（`BASE_BRANCH` 上で起動するため）。`-D` で安全に消せる。

### 4. 監査ログの保持

`.trinity/<run>/` の `plan.md` `eval-*.md` `trinity.log` は**削除しない**。worktree ディレクトリだけ消える。これらは振り返りと再現のために残す。

## 否認時・partial 時のユーザー提示

ユーザーが「PR は残す」を選んだ場合、または `Other` がフェイルセーフで「残す」になった場合、お片付けは行わない。最終出力後に次のコマンドをそのまま 3 行印字して、ユーザーがあとで実行できるようにする。

```shell
git -C "$(pwd)" worktree remove "$WORKTREE_DIR"   # worktree 削除
git -C "$(pwd)" branch -D "$BRANCH"               # ローカルブランチ削除
git -C "$(pwd)" fetch --prune origin              # リモート追跡参照の更新
```

お片付けが partial（途中で失敗）の場合は、未実行のコマンドだけを抜粋して提示する。実行済みのコマンドは出さない。

## 受け渡し

このスキルが返す情報は次のとおり。`trinity-iter-loop` の最終出力に組み込む。

- `MERGE_RESULT` ∈ { `merged`, `declined`, `failed: <理由>` }
- `CLEANUP_RESULT` ∈ { `done`, `skipped`, `partial: <残っている操作>` }

最終出力フォーマットの組み立ては本スキルの責務外。`trinity-iter-loop` のテンプレに値を流し込む。

## やってはいけないこと

- `AskUserQuestion` を複数回呼ぶ（必ず 1 回にまとめる）
- マージ失敗を再試行する（コンフリクトもブランチ保護違反も再試行で解決しない）
- マージ方式を `merge` や `rebase` にする（`squash` で固定。ハーネス由来の細かいコミットを 1 本に集約することが PR の意図）
- `worktree remove --force` を最初から打つ（dirty を握りつぶすので、まず非 force で試す）
- `.trinity/<run>/` の plan.md / eval-*.md / trinity.log を消す（監査価値がある）
- 否認したのにユーザー提示の手動コマンドを出さない（ユーザーが行き詰まる）

# PR #17 レビューコメント解消トレース

このファイルは PR [yjn279/trinity#17](https://github.com/yjn279/trinity/pull/17) の 6 件のレビューコメントと、現行コードベースにおける解決位置の対応を示すトレース文書である。各コメントは作成時点のスキル名（`trinity-*`）を参照しているが、その後 PR #17 において 3 スキル構成（`git-isolated-worktree` / `git-push-and-pr` / `git-merge-and-cleanup`）へのリネームと統合が行われ、コメントが指す行番号は現行 HEAD には存在しない。本文書により、追加コミットの差分だけを見るレビュアーが各コメントの解消を二値で確認できる。

## スキルリネーム経緯

PR #17 の初期コミット時点では Trinity 専用スキル名（`trinity-branch-push`, `trinity-iter-loop`, `trinity-merge-and-cleanup`, `trinity-orchestration-discipline`）が使われていた。その後、再利用性を高めるために `git-*` 汎用スキル名（`git-push-and-pr`, `git-merge-and-cleanup`, `git-isolated-worktree`）へ統合・リネームされた。またイテレーションループ規範（旧 `trinity-iter-loop`）とオーケストレーション規律（旧 `trinity-orchestration-discipline`）は独立スキルとして切り出す必要がないと判断され、`commands/run.md` に統合された。以降に示すトレース表では、旧スキル名から現行の解決位置への対応を記す。

## コメント解消トレース表

| Comment ID | Original Path:Line | Current Resolution | Resolution Summary |
| --- | --- | --- | --- |
| [3207499342](https://github.com/yjn279/trinity/pull/17#discussion_r3207499342) | `skills/trinity-branch-push/SKILL.md:65` | `skills/git-push-and-pr/SKILL.md:20-34, 79-84` | push 前に `ls-remote --heads` で同名リモートブランチの存在を確認し、1行以上返れば即停止する規範が明記されており、`--force` / `--force-with-lease` も明示的に禁止している。 |
| [3207503739](https://github.com/yjn279/trinity/pull/17#discussion_r3207503739) | `skills/trinity-iter-loop/SKILL.md:1` | `removed: trinity-iter-loop/ → commands/run.md:71-115` | イテレーションループ規範は独立スキルとして不要と判断し、`commands/run.md` の「ループ」「判定に応じた分岐」セクションに統合済みで、ディレクトリは削除された。 |
| [3207527625](https://github.com/yjn279/trinity/pull/17#discussion_r3207527625) | `skills/trinity-merge-and-cleanup/SKILL.md:47` | `skills/git-merge-and-cleanup/SKILL.md:53-113` | お片付けの各ステップにフォールバックを規定し Trinity が完結する設計になっている。`partial:` 戻り値はすべてのフォールバックを尽くしてもなお残った場合の最終安全弁であり、完結化の試行を尽くした後にのみ返される（詳細は `partial:` 注釈を参照）。 |
| [3207534384](https://github.com/yjn279/trinity/pull/17#discussion_r3207534384) | `skills/trinity-merge-and-cleanup/SKILL.md:89` | `commands/run.md:163` | `EXTRA_CLEANUP_PATHS = [$RUN_DIR]` を渡す記述があり、監査ログ（`$RUN_DIR`）も含めてお片付けで削除される。 |
| [3207543214](https://github.com/yjn279/trinity/pull/17#discussion_r3207543214) | `skills/trinity-merge-and-cleanup/SKILL.md:27` | `skills/git-merge-and-cleanup/SKILL.md:115-124` | 否認時に `AskUserQuestion` を 2 回目として 1 回だけ呼び改善項目をヒアリングするフローが規定されており、一方的に終了せずユーザーの意向を確認する設計になっている。 |
| [3207546985](https://github.com/yjn279/trinity/pull/17#discussion_r3207546985) | `skills/trinity-orchestration-discipline/SKILL.md:1` | `removed: trinity-orchestration-discipline/ → commands/run.md:37-69` | オーケストレーション規律（直列実行・段間でコードに触らない・出力要約禁止・最終出力以外を喋らない）は独立スキルとして不要と判断し、`commands/run.md` の「ハーネス規範」セクションに統合済みで、ディレクトリは削除された。 |

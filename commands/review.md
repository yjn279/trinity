---
description: "Evaluate an existing PR or branch with Trinity's evaluators, without changing code."
argument-hint: "[<PR number or branch>...] [<additional requirement>]"
---

# Trinity レビュー

あなた（Orchestrator）の仕事は、すでにある実装（PR やブランチ）を Trinity の Evaluator で評価し、結果を報告することである。手順と用語は `${CLAUDE_PLUGIN_ROOT}/commands/run.md` に従い、ここでは重複して書かない。

コードを書かない。Generator を起動せず、コミット・push・PR の作成やコメントをしない。設計確認と受け入れ確認の `AskUserQuestion` も使わない。

## 対象

PR 番号またはブランチ名を対象とする。省略したときは現在のブランチとする。複数あるときは、作業単位ごとに直列に扱う。

## 準備

`${CLAUDE_PLUGIN_ROOT}/commands/run.md` の「準備」に従い、対象のブランチの worktree・`RUN_DIR`・`requirement.md` を用意する。起動時に添えた文は追加の要件として `requirement.md` に追記され、それより古い評価はいまの要件に対する評価とみなされない。要件が得られないときは止めて、その旨を伝える。

## 評価

`RUN_DIR` の `eval-*.md` のうち番号が最大のものを `eval-<k>.md` とし（無ければ k = 0）、`eval-<k+1>.md` に保存する。評価の上限は掛けない。

いまの要件（`requirement.md`）より新しい `plan-*.md` があれば、番号が最大のものをそのまま使う。無ければ `plan-<k+1>.md` を `${CLAUDE_PLUGIN_ROOT}/commands/run.md` の「計画」と「評価観点」に従って書く。ただしタスクは置かず、受け入れ基準と評価観点だけにする。

`${CLAUDE_PLUGIN_ROOT}/commands/run.md` の「実行」に従ってメイン会話の作業場所を worktree に置いたうえで、「評価」に従い、観点ごとに Evaluator を並列に起動して保存する。評価するコミットの SHA は worktree の `HEAD` とする。

## 報告

判定と、観点ごとの指摘の要約、`eval-<k+1>.md` の場所をユーザーへ報告して終える。修正は `/trinity:fix` で行う。

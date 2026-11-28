---
description: "Fix an existing PR or branch based on its latest Trinity evaluation."
argument-hint: "[<PR number or branch>...] [<additional requirement>]"
---

# Trinity 修正

あなた（Orchestrator）の仕事は、すでにある実装（PR やブランチ）を、最新の評価に基づいて Trinity の Generator で修正し、PR へ反映して報告することである。手順と用語は `${CLAUDE_PLUGIN_ROOT}/commands/run.md` に従い、ここでは重複して書かない。

コードを書かない。Evaluator を起動せず、設計確認と受け入れ確認の `AskUserQuestion` も使わない。再評価は `/trinity:review` で行う。

## 対象

PR 番号またはブランチ名を対象とする。省略したときは現在のブランチとする。複数あるときは、作業単位ごとに直列に扱う。

## 準備

`${CLAUDE_PLUGIN_ROOT}/commands/run.md` の「準備」に従い、対象のブランチの worktree と `RUN_DIR` を用意する。起動時に添えた文は `requirement.md` に追記せず、修正の指示として Generator に渡す（追記すると既存の評価がすべて古くなり、修正の根拠を失う）。`/trinity:review` や `/trinity:run` が使った `RUN_DIR` はそのまま再利用される。要件が得られないときは止めて、その旨を伝える。

## 修正

`RUN_DIR` の `eval-*.md` のうち番号が最大のものを `eval-<k>.md` とする。`requirement.md` より新しい評価が1つも無ければ止めて、先に `/trinity:review` を実行するよう伝える。評価の判定は問わない。

`gen-<k+1>-revise.md` が既にあれば、その評価に対する修正は済んでいるので、飛ばして `/trinity:review` を案内する。

無ければ、`${CLAUDE_PLUGIN_ROOT}/commands/run.md` の「実行」に従ってメイン会話の作業場所を worktree に置いたうえで、「実装と修正」に従い、修正の Generator を1体起動する。周の番号は k + 1、計画は番号が最大の `plan-*.md`、評価は `eval-<k>.md` とする。評価の上限は掛けない。Generator が真の失敗を返したら、PR へ反映せず原因を報告して終える。

## PR 作成

`${CLAUDE_PLUGIN_ROOT}/commands/run.md` の「PR 作成」に従う。合格を待たずに反映する。

## 報告

修正のコミットの SHA と PR の URL を報告し、再評価は `/trinity:review` で行うよう伝えて終える。

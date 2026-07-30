#!/usr/bin/env bash
# scripts/steps.sh — ループの各工程（計画・実装・修正・ツール・評価）。loop.sh が読み込む。

# 計画。Planner を起動し、plan.md とタスク一覧 tasks.tsv を作らせる。
plan() {
  local n="$1"
  [ -f "${RUN_DIR}/plan-${n}.md" ] && { cp "${RUN_DIR}/plan-${n}.md" "${RUN_DIR}/plan.md"; return 0; }
  rm -f "${RUN_DIR}/tasks.tsv"   # 古いファイルの誤検出を防ぐ
  actor planner "$(context "$n")" || true
  [ -f "${RUN_DIR}/plan.md" ] && [ -f "${RUN_DIR}/tasks.tsv" ] || fail "plan ${n}: plan.md / tasks.tsv が出ていない"
  cp "${RUN_DIR}/plan.md" "${RUN_DIR}/plan-${n}.md"   # 再開用の控え
}

# 実装。tasks.tsv の1行ごとに Generator を起動する。
generate() {
  local n="$1" idx title files pre
  while IFS=$'\t' read -r idx title files; do
    case "${idx}" in '' | *[!0-9]*) continue ;; esac
    [ -s "${RUN_DIR}/gen-${n}-task-${idx}.md" ] && { log "task ${idx}: 完了済み"; continue; }
    log "loop ${n} task ${idx}: ${title}"
    pre="$(head_sha)"
    actor generator "$(context "$n")
- TaskIndex: ${idx}
- TaskTitle: ${title}
- TaskFiles: ${files}" || true
    progressed "${pre}" "${RUN_DIR}/gen-${n}-task-${idx}.md" "task ${idx}"
  done < "${RUN_DIR}/tasks.tsv"
}

# 修正。FAIL の指摘を、計画の範囲内で Generator に直させる。
revise() {
  local n="$1" pre
  [ -s "${RUN_DIR}/gen-${n}-revise.md" ] && { log "revise ${n}: 完了済み"; return 0; }
  pre="$(head_sha)"
  actor generator "$(context "$n")
- 修正モード: ${RUN_DIR}/eval-$((n - 1)).md の指摘を既存計画の範囲内で修正する。新規タスクは追加しない。" || true
  progressed "${pre}" "${RUN_DIR}/gen-${n}-revise.md" "revise ${n}"
}

# ツールは同じ差分に一度だけ走らせる（出力があれば飛ばす）。
tool() {
  local out="${RUN_DIR}/$1.md"
  [ -s "${out}" ] && { log "$1: 実行済み"; return 0; }
  actor generator "$2" > "${out}.tmp" || log "WARN: $1 が非ゼロで終了した"
  mv "${out}.tmp" "${out}"
}

tools() {
  local base
  base="$(git -C "${WORKTREE_DIR}" merge-base HEAD origin/HEAD 2>/dev/null)" \
    || base="$(git -C "${WORKTREE_DIR}" rev-list --max-parents=0 HEAD | tail -1)"
  tool review "/code-review --fix ${base}..HEAD"
  tool simplify "/simplify"
  # ツールの修正をコミットし、評価が見る差分を確定させる。
  if [ -n "$(git -C "${WORKTREE_DIR}" status --porcelain)" ]; then
    git -C "${WORKTREE_DIR}" add -A && git -C "${WORKTREE_DIR}" commit -q -m "chore: ツールの自動修正を反映する" \
      || fail "tools: ツールの修正をコミットできなかった"
  fi
}

# 評価。本文を eval-<n>.md として保存し、判定値を返す。判定が読めたときだけファイルを確定させる。
evaluate() {
  local n="$1" verdict out="${RUN_DIR}/eval-$1.md"
  actor evaluator "$(context "$n")
- ループ内最終コミット: $(head_sha)
- ツールの出力: ${RUN_DIR}/review.md と ${RUN_DIR}/simplify.md" > "${out}.tmp" \
    || fail "evaluate ${n}: 評価が非ゼロで終了した（${out}.tmp を参照）"
  verdict="$(verdict_of "${out}.tmp")"
  case "${verdict}" in
    PASS | NEEDS_REVISION | FAIL) mv "${out}.tmp" "${out}"; printf '%s' "${verdict}" ;;
    *) fail "evaluate ${n}: VERDICT が読めない（${out}.tmp を参照）" ;;
  esac
}

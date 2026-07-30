#!/usr/bin/env bash
# scripts/steps/plan.sh — 計画。Planner を起動し、plan.md とタスク一覧 tasks.tsv を作らせる。

plan() {
  local n="$1"
  [ -f "${RUN_DIR}/plan-${n}.md" ] && { cp "${RUN_DIR}/plan-${n}.md" "${RUN_DIR}/plan.md"; return 0; }
  rm -f "${RUN_DIR}/tasks.tsv"   # 古いファイルの誤検出を防ぐ
  actor planner "$(agent_body planner)$(context "$n")" || true
  [ -f "${RUN_DIR}/plan.md" ] && [ -f "${RUN_DIR}/tasks.tsv" ] || fail "plan ${n}: plan.md / tasks.tsv が出ていない"
  cp "${RUN_DIR}/plan.md" "${RUN_DIR}/plan-${n}.md"   # 再開用の控え
}

#!/usr/bin/env bash
# scripts/steps/generate.sh — 実装。tasks.tsv の1行ごとに Generator を起動する。

generate() {
  local n="$1" idx title files pre
  while IFS=$'\t' read -r idx title files; do
    case "${idx}" in '' | *[!0-9]*) continue ;; esac
    [ -s "${RUN_DIR}/gen-${n}-task-${idx}.md" ] && { log "task ${idx}: 完了済み"; continue; }
    log "loop ${n} task ${idx}: ${title}"
    pre="$(head_sha)"
    actor generator "$(agent_body generator)$(context "$n")
- TaskIndex: ${idx}
- TaskTitle: ${title}
- TaskFiles: ${files}" || true
    progressed "${pre}" "${RUN_DIR}/gen-${n}-task-${idx}.md" "task ${idx}"
  done < "${RUN_DIR}/tasks.tsv"
}

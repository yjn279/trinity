#!/usr/bin/env bash
# scripts/steps/revise.sh — 修正。FAIL の指摘を、計画の範囲内で Generator に直させる。

revise() {
  local n="$1" pre
  [ -s "${RUN_DIR}/gen-${n}-revise.md" ] && { log "revise ${n}: 完了済み"; return 0; }
  pre="$(head_sha)"
  actor generator "$(agent_body generator)$(context "$n")
- 修正モード: ${RUN_DIR}/eval-$((n - 1)).md の指摘を既存計画の範囲内で修正する。新規タスクは追加しない。" || true
  progressed "${pre}" "${RUN_DIR}/gen-${n}-revise.md" "revise ${n}"
}

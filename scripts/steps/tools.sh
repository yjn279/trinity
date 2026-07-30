#!/usr/bin/env bash
# scripts/steps/tools.sh — ツール。/code-review --fix と /simplify を同じ差分に一度だけ走らせる。

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

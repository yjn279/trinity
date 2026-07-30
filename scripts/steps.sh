#!/usr/bin/env bash
# scripts/steps.sh — ループの各段（計画・実装・修正・道具・評価）。loop.sh が読み込む。

agent_body()  { awk 'f==2 {print} /^---$/ {f++}' "${TRINITY_ROOT}/agents/$1.md"; }
agent_model() { awk -F': *' '/^model:/ {print $2; exit}' "${TRINITY_ROOT}/agents/$1.md"; }
head_sha()    { git -C "${WORKTREE_DIR}" rev-parse HEAD 2>/dev/null || true; }

# VERDICT 行から判定値を読む。記号と空白の飾りは取り除いてから照合する。
verdict_of() { tr -d '`*#> \t' < "$1" | grep -m1 -oE '^VERDICT:[A-Z_]+' | cut -d: -f2 || true; }

context() {
  printf '\n## このランの入力\n- RUN_DIR: %s\n- WORKTREE_DIR: %s\n- BRANCH: %s\n- 現在のループ番号: %s\n- 要件: %s/requirement.md を読むこと\n' \
    "${RUN_DIR}" "${WORKTREE_DIR}" "${BRANCH}" "$1" "${RUN_DIR}"
}

# claude を子プロセスとして1回起動する。CLAUDECODE を外して入れ子と誤検出されるのを避け、
# guard.sh をフックとして注入して役割の権限を制限する。
actor() {
  ( cd "${WORKTREE_DIR}" && env -u CLAUDECODE TRINITY_ROLE="$1" \
      claude -p "$2" --model "$(agent_model "$1")" \
      --permission-mode bypassPermissions --strict-mcp-config \
      --settings "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Write|Edit|NotebookEdit|Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"${TRINITY_ROOT}/scripts/guard.sh\"}]}]}}" )
}

# コミットか空でない完了レポートがあれば前進とみなし、どちらも無ければ失敗として止める。
progressed() {
  [ "$1" != "$(head_sha)" ] || [ -s "$2" ] || fail "$3: コミットも完了レポートも作られなかった"
}

plan() {
  local n="$1"
  [ -f "${RUN_DIR}/plan-${n}.md" ] && { cp "${RUN_DIR}/plan-${n}.md" "${RUN_DIR}/plan.md"; return 0; }
  rm -f "${RUN_DIR}/tasks.tsv"   # 古いファイルの誤検出を防ぐ
  actor planner "$(agent_body planner)$(context "$n")" || true
  [ -f "${RUN_DIR}/plan.md" ] && [ -f "${RUN_DIR}/tasks.tsv" ] || fail "plan ${n}: plan.md / tasks.tsv が出ていない"
  cp "${RUN_DIR}/plan.md" "${RUN_DIR}/plan-${n}.md"   # 再開用の控え
}

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

revise() {
  local n="$1" pre
  [ -s "${RUN_DIR}/gen-${n}-revise.md" ] && { log "revise ${n}: 完了済み"; return 0; }
  pre="$(head_sha)"
  actor generator "$(agent_body generator)$(context "$n")
- 修正モード: ${RUN_DIR}/eval-$((n - 1)).md の指摘を既存計画の範囲内で修正する。新規タスクは追加しない。" || true
  progressed "${pre}" "${RUN_DIR}/gen-${n}-revise.md" "revise ${n}"
}

# 道具は同じ差分に一度だけ走らせる（出力があれば飛ばす）。
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
  # 道具の修正をコミットし、評価が見る差分を確定させる。
  if [ -n "$(git -C "${WORKTREE_DIR}" status --porcelain)" ]; then
    git -C "${WORKTREE_DIR}" add -A && git -C "${WORKTREE_DIR}" commit -q -m "chore: 道具の自動修正を反映する" \
      || fail "tools: 道具の修正をコミットできなかった"
  fi
}

# 評価の本文を eval-<n>.md として保存し、判定値を返す。判定が読めたときだけファイルを確定させる。
evaluate() {
  local n="$1" verdict out="${RUN_DIR}/eval-$1.md"
  actor evaluator "$(agent_body evaluator)$(context "$n")
- ループ内最終コミット: $(head_sha)
- 道具の出力: ${RUN_DIR}/review.md と ${RUN_DIR}/simplify.md" > "${out}.tmp" \
    || fail "evaluate ${n}: 評価が非ゼロで終了した（${out}.tmp を参照）"
  verdict="$(verdict_of "${out}.tmp")"
  case "${verdict}" in
    PASS | NEEDS_REVISION | FAIL) mv "${out}.tmp" "${out}"; printf '%s' "${verdict}" ;;
    *) fail "evaluate ${n}: VERDICT が読めない（${out}.tmp を参照）" ;;
  esac
}

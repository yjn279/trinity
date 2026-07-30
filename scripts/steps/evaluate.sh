#!/usr/bin/env bash
# scripts/steps/evaluate.sh — 評価。Evaluator を起動し、判定が読めたときだけ eval-<n>.md を確定する。

evaluate() {
  local n="$1" verdict out="${RUN_DIR}/eval-$1.md"
  actor evaluator "$(agent_body evaluator)$(context "$n")
- ループ内最終コミット: $(head_sha)
- ツールの出力: ${RUN_DIR}/review.md と ${RUN_DIR}/simplify.md" > "${out}.tmp" \
    || fail "evaluate ${n}: 評価が非ゼロで終了した（${out}.tmp を参照）"
  verdict="$(verdict_of "${out}.tmp")"
  case "${verdict}" in
    PASS | NEEDS_REVISION | FAIL) mv "${out}.tmp" "${out}"; printf '%s' "${verdict}" ;;
    *) fail "evaluate ${n}: VERDICT が読めない（${out}.tmp を参照）" ;;
  esac
}

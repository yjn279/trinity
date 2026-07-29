#!/usr/bin/env bash
# scripts/loop.sh — 1つの作業単位の収束ループ（計画 → 実装 → 道具 → 評価）を回す。
# 使い方: loop.sh <RUN_DIR> <WORKTREE_DIR> <BRANCH>
# 評価が PASS を返すまで、開始ループから最大 TRINITY_MAX_LOOPS 回（既定 5）反復する。
# 各段の成果物を RUN_DIR に残し、再起動時はそこから中断点を判定して完了済みの段を飛ばす。
# RUN_DIR/redrive（修正要望の合図。本文は Orchestrator が requirement.md へ追記済み）が
# あれば、PASS 済みでも再収束する。ログはすべて標準エラーに流す。
set -euo pipefail

TRINITY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${1:?usage: loop.sh <RUN_DIR> <WORKTREE_DIR> <BRANCH>}"
WORKTREE_DIR="${2:?WORKTREE_DIR required}"
BRANCH="${3:?BRANCH required}"
export TRINITY_ROOT RUN_DIR WORKTREE_DIR BRANCH
: "${TRINITY_MAX_LOOPS:=5}"
mkdir -p "${RUN_DIR}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# 状態を1語で記録する。passed / failed / error が終端。終端では pid を消して「pid の有無」を
# 走行中の信号にし、passed / failed では redrive も消して再収束を完了扱いにする。error では
# redrive を残し、未完の再収束を続きから拾えるようにする。
status() {
  printf '%s\n' "$1" > "${RUN_DIR}/status"
  log "status -> $1"
  case "$1" in
    passed | failed) rm -f "${RUN_DIR}/redrive" "${RUN_DIR}/pid" ;;
    error)           rm -f "${RUN_DIR}/pid" ;;
  esac
}

fail() { log "$*"; status error; exit 1; }

agent_body()  { awk 'f==2 {print} /^---$/ {f++}' "${TRINITY_ROOT}/agents/$1.md"; }
agent_model() { awk -F': *' '/^model:/ {print $2; exit}' "${TRINITY_ROOT}/agents/$1.md"; }
head_sha()    { git -C "${WORKTREE_DIR}" rev-parse HEAD 2>/dev/null || true; }

# eval-*.md の VERDICT 行から値を読む。装飾（バッククォート・*・#・>・空白）は取り除いて照合する。
verdict_of() { tr -d '`*#> \t' < "$1" | grep -m1 -oE '^VERDICT:[A-Z_]+' | cut -d: -f2 || true; }

context() {
  printf '\n## このランの入力\n- RUN_DIR: %s\n- WORKTREE_DIR: %s\n- BRANCH: %s\n- 現在のループ番号: %s\n- 要件: %s/requirement.md を読むこと\n' \
    "${RUN_DIR}" "${WORKTREE_DIR}" "${BRANCH}" "$1" "${RUN_DIR}"
}

# headless な claude を1回起動する。CLAUDECODE を外してネスト起動を避け、bypassPermissions で
# worktree のツールを許可しつつ、guard.sh を PreToolUse フックとして注入して役割境界を課す。
actor() {
  ( cd "${WORKTREE_DIR}" && env -u CLAUDECODE TRINITY_ROLE="$1" \
      claude -p "$2" --model "$(agent_model "$1")" \
      --permission-mode bypassPermissions --strict-mcp-config \
      --settings "{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Write|Edit|NotebookEdit|Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"${TRINITY_ROOT}/scripts/guard.sh\"}]}]}}" )
}

# コミットか空でない完了レポートのどちらかを実装役の前進とみなし、どちらも無ければ真の失敗。
progressed() {
  [ "$1" != "$(head_sha)" ] || [ -s "$2" ] || fail "$3: コミットも完了レポートも作られなかった"
}

plan() {
  local n="$1"
  [ -f "${RUN_DIR}/plan-${n}.md" ] && { cp "${RUN_DIR}/plan-${n}.md" "${RUN_DIR}/plan.md"; return 0; }
  rm -f "${RUN_DIR}/tasks.tsv"   # 失敗時に古いファイルを誤検出しない
  actor planner "$(agent_body planner)$(context "$n")" || true
  [ -f "${RUN_DIR}/plan.md" ] && [ -f "${RUN_DIR}/tasks.tsv" ] || fail "plan ${n}: plan.md / tasks.tsv が出ていない"
  cp "${RUN_DIR}/plan.md" "${RUN_DIR}/plan-${n}.md"   # 再開のチェックポイント
}

generate() {
  local n="$1" idx title files pre
  while IFS=$'\t' read -r idx title files; do
    case "${idx}" in '' | *[!0-9]*) continue ;; esac   # 空行・ヘッダ行を飛ばす
    [ -s "${RUN_DIR}/gen-${n}-task-${idx}.md" ] && { log "task ${idx}: スキップ（完了済み）"; continue; }
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
  [ -s "${RUN_DIR}/gen-${n}-revise.md" ] && { log "revise ${n}: スキップ（完了済み）"; return 0; }
  pre="$(head_sha)"
  actor generator "$(agent_body generator)$(context "$n")
- 修正モード: ${RUN_DIR}/eval-$((n - 1)).md の指摘を既存計画の範囲内で修正する。新規タスクは追加しない。" || true
  progressed "${pre}" "${RUN_DIR}/gen-${n}-revise.md" "revise ${n}"
}

# 道具はこの差分につき一度だけ走らせ（出力があればスキップ）、同じ指摘の入れ直しを防ぐ。
tool() {
  local out="${RUN_DIR}/$1.md"
  [ -s "${out}" ] && { log "$1: スキップ（この差分に実行済み）"; return 0; }
  actor generator "$2" > "${out}.tmp" || log "WARN: $1 が非ゼロで終了した"
  mv "${out}.tmp" "${out}"
}

tools() {
  local base
  base="$(git -C "${WORKTREE_DIR}" merge-base HEAD origin/HEAD 2>/dev/null)" \
    || base="$(git -C "${WORKTREE_DIR}" rev-list --max-parents=0 HEAD | tail -1)"
  tool review "/code-review --fix ${base}..HEAD"
  tool simplify "/simplify"
  # 道具の修正をコミットし、評価が見る差分を確定させる（ハーネス自身の git はフック対象外）。
  if [ -n "$(git -C "${WORKTREE_DIR}" status --porcelain)" ]; then
    git -C "${WORKTREE_DIR}" add -A && git -C "${WORKTREE_DIR}" commit -q -m "chore: 道具の自動修正を反映する" \
      || fail "tools: 道具の修正をコミットできなかった"
  fi
}

# 評価の本文を eval-<n>.md として確定し、判定値を標準出力に返す。改名の前に VERDICT を
# 検めるため、eval-<n>.md が「在る」＝「判定が取れた」が成り立つ。
evaluate() {
  local n="$1" verdict out="${RUN_DIR}/eval-$1.md"
  actor evaluator "$(agent_body evaluator)$(context "$n")
- ループ内最終コミット: $(head_sha)
- 道具の出力: ${RUN_DIR}/review.md と ${RUN_DIR}/simplify.md" > "${out}.tmp" \
    || fail "evaluate ${n}: Evaluator が非ゼロで終了した（${out}.tmp を参照）"
  verdict="$(verdict_of "${out}.tmp")"
  case "${verdict}" in
    PASS | NEEDS_REVISION | FAIL) mv "${out}.tmp" "${out}"; printf '%s' "${verdict}" ;;
    *) fail "evaluate ${n}: VERDICT が読めない（${out}.tmp を参照）" ;;
  esac
}

# pid を主張して二重起動を防ぐ。起動は Orchestrator が直列に行うため、生存確認だけで足りる。
if [ -s "${RUN_DIR}/pid" ] && kill -0 "$(cat "${RUN_DIR}/pid")" 2>/dev/null; then
  log "既に実行中（pid $(cat "${RUN_DIR}/pid")）。何もせず終了する。"
  exit 0
fi
printf '%s\n' "$$" > "${RUN_DIR}/pid"

# 最大の eval 番号とその判定から再開位置を決める。redrive があるときは PASS でも短絡しない。
k=0 last=""
for f in "${RUN_DIR}"/eval-*.md; do
  [ -f "$f" ] || continue
  n="${f##*/eval-}"; n="${n%.md}"
  case "$n" in *[!0-9]*) continue ;; esac
  [ "$n" -gt "$k" ] && { k="$n"; last="$(verdict_of "$f")"; }
done
if [ "$k" -eq 0 ]; then
  loop=1 mode=plan
elif [ -f "${RUN_DIR}/redrive" ]; then
  loop=$((k + 1)) mode=plan
elif [ "$last" = PASS ]; then
  log "既に PASS 済み。再実行しない。"
  status passed
  exit 0
else
  loop=$((k + 1))
  [ "$last" = NEEDS_REVISION ] && mode=plan || mode=revise
fi

max_loop=$((loop + TRINITY_MAX_LOOPS - 1))
status running
log "開始: ${BRANCH}（ループ ${loop}・${mode} から）"

while [ "${loop}" -le "${max_loop}" ]; do
  if [ "${mode}" = plan ]; then
    plan "${loop}"
    generate "${loop}"
  else
    revise "${loop}"
  fi
  tools
  verdict="$(evaluate "${loop}")" || exit 1
  case "${verdict}" in
    PASS)           log "ループ ${loop} で PASS。PR 作成へ。"; status passed; exit 0 ;;
    NEEDS_REVISION) mode=plan ;;
    FAIL)           mode=revise ;;
  esac
  loop=$((loop + 1))
done

status failed
log "ループ ${max_loop} まで回したが PASS に到達しなかった"
exit 2

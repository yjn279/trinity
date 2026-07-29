#!/usr/bin/env bash
# scripts/loop.sh — 1つの作業単位の収束ループを回す。使い方: loop.sh <RUN_DIR> <WORKTREE_DIR> <BRANCH>
# 評価が PASS を返すまで、開始ループから最大 TRINITY_MAX_LOOPS 回（既定 5）反復する。各段
# （scripts/stages.sh）の成果物を RUN_DIR に残し、再起動時はそこから中断点を判定して完了済みの
# 段を飛ばす。RUN_DIR/redrive（修正要望の合図。本文は Orchestrator が requirement.md へ追記済み）
# があれば、PASS 済みでも再収束する。ログはすべて標準エラーに流す。
set -euo pipefail

TRINITY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${1:?usage: loop.sh <RUN_DIR> <WORKTREE_DIR> <BRANCH>}"
WORKTREE_DIR="${2:?WORKTREE_DIR required}"
BRANCH="${3:?BRANCH required}"
export TRINITY_ROOT RUN_DIR WORKTREE_DIR BRANCH
: "${TRINITY_MAX_LOOPS:=5}"

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

# shellcheck source=scripts/stages.sh
. "${TRINITY_ROOT}/scripts/stages.sh"

# pid を主張して二重起動を防ぐ。起動は Orchestrator が直列に行うため、生存確認だけで足りる。
kill -0 "$(cat "${RUN_DIR}/pid" 2>/dev/null)" 2>/dev/null && { log "既に実行中。何もしない。"; exit 0; }
printf '%s\n' "$$" > "${RUN_DIR}/pid"

# 最大の eval 番号とその判定から再開位置を決める。redrive があるときは PASS でも短絡しない。
k=0 last=""
for f in "${RUN_DIR}"/eval-*.md; do
  n="${f##*/eval-}"; n="${n%.md}"
  [ -f "$f" ] && [ "$n" -gt "$k" ] 2>/dev/null && { k="$n"; last="$(verdict_of "$f")"; }
done
loop=$((k + 1)) mode=plan
if [ ! -f "${RUN_DIR}/redrive" ]; then
  [ "$last" = PASS ] && { log "既に PASS 済み。再実行しない。"; status passed; exit 0; }
  [ "$last" = FAIL ] && mode=revise
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

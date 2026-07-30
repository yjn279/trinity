#!/usr/bin/env bash
# scripts/loop.sh — 1つの作業単位の収束ループ（計画 → 実装 → ツール → 評価）を PASS まで回す。
# 使い方: loop.sh <RUN_DIR> <WORKTREE_DIR> <BRANCH>
# 成果物は RUN_DIR に残し、再起動時は完了済みの工程を飛ばして途中から再開する。
# RUN_DIR/redrive（修正要望の合図。本文は requirement.md に追記済み）があれば作り直す。
set -euo pipefail

TRINITY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${1:?usage: loop.sh <RUN_DIR> <WORKTREE_DIR> <BRANCH>}"
WORKTREE_DIR="${2:?WORKTREE_DIR required}"
BRANCH="${3:?BRANCH required}"
export TRINITY_ROOT RUN_DIR WORKTREE_DIR BRANCH
: "${TRINITY_MAX_LOOPS:=5}"
mkdir -p "${RUN_DIR}"

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

# 状態を1語で記録する。passed / failed / error が終了状態。終了時に pid を消し、passed / failed
# では redrive も消す。error では redrive を残し、再起動で続きから再開できるようにする。
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

# 各工程を読み込む。
for f in "${TRINITY_ROOT}/scripts/steps/"*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done

# 二重起動を防ぐ。起動元が直列に呼ぶため、生存確認だけでよい。
kill -0 "$(cat "${RUN_DIR}/pid" 2>/dev/null)" 2>/dev/null && { log "既に実行中。何もしない。"; exit 0; }
printf '%s\n' "$$" > "${RUN_DIR}/pid"

# 最後の評価とその判定から再開位置を決める。redrive があれば PASS 済みでも作り直す。
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

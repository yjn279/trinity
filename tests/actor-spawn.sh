#!/usr/bin/env bash
# tests/actor-spawn.sh — trinity::spawn のメモリ preflight と死亡検知を検証する。
# bats に依存せず素の bash で完結し、`bash tests/actor-spawn.sh` で走る。
#
# claude 起動（trinity::claude）とメモリ計測（trinity::memory_available_pct）をスタブに
# 差し替え、preflight abort / SIGKILL 検知 / 通常終了 / 測定不能時スキップ を確認する。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/actors.sh
. "${ROOT}/lib/actors.sh"

RUN_DIR="$(mktemp -d)"; export RUN_DIR
CALLED="${RUN_DIR}/claude_called"
trap 'rm -rf "$RUN_DIR"' EXIT

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
ng() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# スタブ: claude 起動は marker を書いて STUB_RC を返す。メモリ％は STUB_PCT を返す。
STUB_RC=0; STUB_PCT=50
trinity::claude() { : > "${CALLED}"; return "${STUB_RC}"; }
trinity::memory_available_pct() { printf '%s' "${STUB_PCT}"; }

run() { # run ROLE — spawn を1回呼び、戻り値を返す
  rm -f "${CALLED}"
  local rc=0
  trinity::spawn "$1" model /tmp "prompt" "${RUN_DIR}/out" || rc=$?
  echo "$rc"
}

# 1. 低メモリ → 起動せず RC_LOW_MEMORY、claude は呼ばれない
STUB_PCT=5; STUB_RC=0
rc="$(TRINITY_MIN_FREE_PCT=15 run generator)"
[ "$rc" = "${TRINITY_RC_LOW_MEMORY}" ] && ok "低メモリ(5%<15%) → RC_LOW_MEMORY(${rc})" || ng "低メモリ → ${rc}, want ${TRINITY_RC_LOW_MEMORY}"
[ ! -f "${CALLED}" ] && ok "低メモリ時 claude を起動しない" || ng "低メモリなのに claude を起動した"

# 2. 十分なメモリ + 通常終了 → 0、claude は呼ばれる
STUB_PCT=50; STUB_RC=0
rc="$(TRINITY_MIN_FREE_PCT=15 run generator)"
[ "$rc" = 0 ] && ok "十分メモリ + 正常終了 → 0" || ng "正常終了 → ${rc}, want 0"
[ -f "${CALLED}" ] && ok "十分メモリ時 claude を起動する" || ng "claude を起動しなかった"

# 3. SIGKILL 相当(137) → RC_KILLED
STUB_PCT=50; STUB_RC=137
rc="$(TRINITY_MIN_FREE_PCT=15 run planner)"
[ "$rc" = "${TRINITY_RC_KILLED}" ] && ok "SIGKILL(137) → RC_KILLED(${rc})" || ng "SIGKILL → ${rc}, want ${TRINITY_RC_KILLED}"

# 4. 通常の非ゼロ(1) は kill 扱いしない → そのまま 1（出力の中身は呼び出し側が判定）
STUB_PCT=50; STUB_RC=1
rc="$(TRINITY_MIN_FREE_PCT=15 run generator)"
[ "$rc" = 1 ] && ok "通常エラー(1) は kill 扱いせず素通し" || ng "通常エラー → ${rc}, want 1"

# 5. 測定不能(空)なら preflight をスキップして起動する（P3 の死亡検知が backstop）
STUB_PCT=""; STUB_RC=0
rc="$(TRINITY_MIN_FREE_PCT=99 run generator)"
[ "$rc" = 0 ] && ok "測定不能 → preflight スキップして起動" || ng "測定不能 → ${rc}, want 0"

# 6. 実機のメモリ％取得（別プロセスで本物を呼び、整数が返るか）
real_pct="$(bash -c '. "'"${ROOT}"'/lib/actors.sh"; trinity::memory_available_pct' 2>/dev/null || true)"
case "${real_pct}" in
  '' ) ok "memory_available_pct: 本 OS では測定不能（空=スキップ扱い）" ;;
  *[!0-9]* ) ng "memory_available_pct が非整数を返した: [${real_pct}]" ;;
  * ) ok "memory_available_pct: 実機で ${real_pct}% を取得" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# tests/guard-git.sh — lib/guard.sh の Bash 経由 git 検査を、旧 shim と同じ deny/allow で
# 判定できるか検証する。bats に依存せず素の bash で完結し、`bash tests/guard-git.sh` で走る。
#
# 各ケースは PreToolUse フックの JSON を stdin から guard.sh に流し、stdout に deny 決定
# （"permissionDecision":"deny"）が出るか否かを期待値と突き合わせる。alias 迂回検知は、
# 使い捨てリポジトリに実際の alias を仕込んでから検証する。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${ROOT}/lib/guard.sh"

pass=0
fail=0

# json_escape STRING — command 文字列を JSON の文字列値へエスケープする（\ → \\、" → \"、改行 → \n）。
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# run_case ROLE COMMAND EXPECT [CWD] — EXPECT は deny または allow。CWD を渡すと alias 解決の
# 起点となる作業ディレクトリをそこへ切り替えて guard.sh を起動する（未指定なら現在地）。
run_case() {
  local role="$1" command="$2" expect="$3" cwd="${4:-.}" json out got
  json="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$(json_escape "$command")")"
  out="$(cd "$cwd" && printf '%s' "$json" | TRINITY_ROLE="$role" bash "$GUARD" 2>/dev/null || true)"
  case "$out" in
    *'"permissionDecision":"deny"'*) got=deny ;;
    *) got=allow ;;
  esac
  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1))
    printf 'ok   [%s] %-45s -> %s\n' "$role" "$command" "$got"
  else
    fail=$((fail + 1))
    printf 'FAIL [%s] %-45s -> got %s, want %s\n' "$role" "$command" "$got" "$expect"
  fi
}

# ── deny 系（旧 shim と同じ理由で拒否される） ──────────────────────────────
run_case generator "git push"                                  deny
run_case generator "git commit --amend"                        deny
run_case generator "git commit --no-verify"                    deny
run_case generator "git -c core.fsmonitor='!id' status"        deny  # -c は role 非依存で deny
run_case planner   "git -c core.fsmonitor='!id' status"        deny
run_case generator "git config alias.x '!git push'"            deny
run_case generator "git config alias.x '!git push' && git x"   deny  # 複合コマンドを境界で走査
run_case generator "foo=\$(git push)"                          deny  # コマンド置換内も ( ) 境界で拾う
run_case generator "$(printf 'git \\\npush')"                  deny  # 行継続をまたいでも push を拾う
run_case planner   "git commit -m x"                           deny
run_case evaluator "git checkout -b foo"                       deny

# ── allow 系 ────────────────────────────────────────────────────────────────
run_case planner   "git log"                                   allow
run_case evaluator "git status"                                allow
run_case generator 'git commit -m "msg"'                       allow
run_case generator 'git commit -m "wip; git push later"'       allow  # 引用符内の区切りは境界にしない
run_case generator "git add file.txt"                          allow
run_case planner   "git rev-parse HEAD"                        allow
run_case generator "echo git push"                             allow

# ── alias 迂回検知（実 alias を仕込んで検証） ──────────────────────────────
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
git -C "$tmp" config alias.p '!git push'
git -C "$tmp" config alias.ci 'commit --amend'
run_case generator "git p"    deny  "$tmp"   # shell alias 展開 -> deny
run_case generator "git ci"   deny  "$tmp"   # commit --amend 展開 -> deny
run_case generator "git log"  allow "$tmp"   # alias でない読み取りは通る

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

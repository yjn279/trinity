#!/usr/bin/env bash
# scripts/test-guard.sh — guard.sh の Bash 経由 git 検査を確認する。`bash scripts/test-guard.sh` で走る。
# 各ケースはフックの JSON を stdin から guard.sh に流し、deny 決定の有無を期待値と突き合わせる。
set -euo pipefail

GUARD="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/guard.sh"
pass=0 fail=0

# run_case ROLE COMMAND EXPECT — EXPECT は deny または allow。
run_case() {
  local role="$1" command="$2" expect="$3" json out got
  command="${command//\\/\\\\}"; command="${command//\"/\\\"}"; command="${command//$'\n'/\\n}"
  json="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$command")"
  out="$(printf '%s' "$json" | TRINITY_ROLE="$role" bash "$GUARD" 2>/dev/null || true)"
  case "$out" in *'"permissionDecision":"deny"'*) got=deny ;; *) got=allow ;; esac
  if [ "$got" = "$expect" ]; then
    pass=$((pass + 1)); printf 'ok   [%s] %-46s -> %s\n' "$role" "$command" "$got"
  else
    fail=$((fail + 1)); printf 'FAIL [%s] %-46s -> got %s, want %s\n' "$role" "$command" "$got" "$expect"
  fi
}

# 状態変更の禁止
run_case generator "git push"                                  deny
run_case generator "git commit --amend"                        deny
run_case generator "git commit --no-verify"                    deny
run_case generator "git config alias.x '!git push'"            deny  # config 書き込み（alias 定義）
run_case generator "git -c core.fsmonitor='!id' status"        deny  # -c は role 非依存で deny
run_case planner   "git -c core.fsmonitor='!id' status"        deny

# 一覧外のサブコマンド（alias 名・未知語を含む）は deny
run_case generator "git p"                                     deny
run_case generator "git frobnicate"                            deny
run_case generator "git fetch"                                 deny  # network は generator の一覧外
run_case planner   "git commit -m x"                           deny  # commit は読み取り専用外
run_case evaluator "git checkout -b foo"                       deny

# git を含む複合コマンド・埋め込みは deny（安全に切り出せない）
run_case generator "git add . && git commit -m x"              deny
run_case generator "git config alias.x '!git push' && git x"   deny
run_case generator "foo=\$(git push)"                          deny  # コマンド置換
run_case generator "$(printf 'git \\\npush')"                  deny  # 行継続
run_case planner   "git log | head"                            deny  # パイプ
run_case generator "xargs git push"                            deny  # git が先頭コマンドでない

# allow 系
run_case planner   "git log"                                   allow
run_case evaluator "git status"                                allow
run_case planner   "git rev-parse HEAD"                        allow
run_case generator 'git commit -m "msg"'                       allow
run_case generator 'git commit -m "wip; git push later"'       allow  # 引用符内の区切りは境界にしない
run_case generator "git add file.txt"                          allow
run_case generator "git checkout main"                         allow
run_case generator "git reset --hard HEAD~1"                   allow
run_case generator 'echo "git push"'                           allow  # 引用句は一語で git 語にならない
run_case generator "npm test && npm run build"                 allow  # git を含まない複合は対象外

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

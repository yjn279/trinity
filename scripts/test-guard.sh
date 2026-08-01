#!/usr/bin/env bash
# scripts/test-guard.sh — guard.sh の git コマンドの判定を確認する。`bash scripts/test-guard.sh` で走る。
# 各ケースはフックの JSON を guard.sh に流し、拒否になるかどうかを期待値と突き合わせる。
set -euo pipefail

GUARD="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/guard.sh"
export WORKTREE_DIR=/tmp/wt
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
run_case generator "git config alias.x '!git push'"            deny  # 設定の変更（別名の定義）
run_case generator "git -c core.fsmonitor='!id' status"        deny  # -c は役割によらず拒否
run_case planner   "git -c core.fsmonitor='!id' status"        deny

# 一覧に無いサブコマンド（別名・未知の語を含む）は拒否
run_case generator "git p"                                     deny
run_case generator "git frobnicate"                            deny
run_case generator "git fetch"                                 deny  # 通信は generator の一覧に無い
run_case generator "git merge main"                            deny  # 一覧を中核だけに絞った
run_case planner   "git commit -m x"                           deny  # commit は読み取り専用の役割に無い
run_case evaluator "git checkout -b foo"                       deny

# git を含む複合コマンド・埋め込み・判定できない形は拒否
run_case generator "git add . && git commit -m x"              deny
run_case generator "git config alias.x '!git push' && git x"   deny
run_case generator "foo=\$(git push)"                          deny  # コマンド置換
run_case generator "$(printf 'git \\\npush')"                  deny  # バックスラッシュ（行の折り返し）
run_case generator "$(printf 'git log\ngit push')"             deny  # 改行による複合
run_case planner   "git log | head"                            deny  # パイプ
run_case generator "git diff > out.txt"                        deny  # 入出力の付け替え
run_case generator "xargs git push"                            deny  # git が先頭コマンドでない
run_case generator "/usr/bin/git push"                         deny  # パス指定の git も同じ
run_case generator "git commit -m \"it's done\""               deny  # 引用符の混在
run_case generator 'g"it" push'                                deny  # 引用符で git の語を組み立てる形
run_case generator "gi't' push"                                deny
run_case generator 'g\it push'                                 deny  # バックスラッシュで組み立てる形

# 許可されるもの
run_case planner   "git log"                                   allow
run_case evaluator "git status"                                allow
run_case planner   "git rev-parse HEAD"                        allow
run_case evaluator 'git -C "${WORKTREE_DIR}" status'           allow  # 作業場所の変数は値に置き換えて判定
run_case generator 'git commit -m "msg"'                       allow
run_case generator 'git commit -m "wip; git push later"'       allow  # 引用符の中の区切りは境界にしない
run_case generator "git commit -m 'fix(scope): a & b'"         allow
run_case generator "git add file.txt"                          allow
run_case generator "git checkout main"                         allow
run_case generator "git reset --hard HEAD~1"                   allow
run_case generator 'git log
'                                                              allow  # 末尾の改行は複合にしない
run_case generator 'echo "git push"'                           allow  # 語全体の引用の中の git は対象外
run_case generator "cat .gitignore"                            allow  # 語の中の git は git の語ではない
run_case generator "npm test && npm run build"                 allow  # git を含まない複合は対象外

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

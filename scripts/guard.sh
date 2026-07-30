#!/usr/bin/env bash
# scripts/guard.sh — 各役割の権限を制限するフック（PreToolUse）。許可・拒否の判断はここが正。
# 入力のフック JSON から道具名と引数を読み、役割（TRINITY_ROLE）に応じて拒否の JSON を返す
# （何も返さなければ許可）。git は許可一覧に載るサブコマンドだけを許し、設定の変更
# （config・-c）と、git を含む複合コマンドは常に拒否する。
set -euo pipefail

TRINITY_ROLE="${TRINITY_ROLE:-}"
READ_GIT="log|show|diff|status|rev-parse|blame|cat-file|ls-files|ls-tree|for-each-ref|rev-list|describe|shortlog|show-ref|name-rev|grep|var|help|version"
WRITE_GIT="add|checkout|switch|restore|reset|revert|cherry-pick|merge|rebase|stash|mv|rm|clean|apply|branch|tag|notes|commit"

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# "KEY":"値" の形の文字列を1つ取り出し、JSON で置き換えられた記号を元の文字に戻す。
field() {
  local raw
  raw="$(printf '%s' "$2" | grep -Eo '"'"$1"'"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -1 \
    | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  raw="${raw//\\\\/$'\x01'}"; raw="${raw//\\n/$'\n'}"; raw="${raw//\\t/$'\t'}"
  raw="${raw//\\r/$'\r'}"; raw="${raw//\\\"/\"}"; raw="${raw//\\\///}"; raw="${raw//$'\x01'/\\}"
  printf '%s' "$raw"
}

# 書き込みの範囲。evaluator は全面拒否、planner は RUN_DIR の中だけ（境界を越えうる「..」を
# 含むパスは判定せず拒否する）、generator は制限なし。
check_write() {
  case "${TRINITY_ROLE}" in
    generator) ;;
    planner)
      [ -n "${RUN_DIR:-}" ] || deny "plannerはRUN_DIR未設定のため書き込み範囲を判定できない"
      case "$1" in
        *..*) deny "plannerは .. を含むパスへ書き込めない: $1" ;;
        "${RUN_DIR%/}" | "${RUN_DIR%/}"/*) ;;
        *) deny "plannerはRUN_DIR外へ書き込めない: $1" ;;
      esac ;;
    *) deny "role=${TRINITY_ROLE} はWrite/Editを実行できない" ;;
  esac
}

# git の引数を役割の許可一覧で判定する。設定の変更は別名の定義やコマンド実行を仕込めるため
# config・-c とも常に拒否し、-C などの場所指定は値ごと読み飛ばしてサブコマンドを探す。
check_git() {
  local sub="" i=0 t allowed args=("$@") rest=()
  while [ "$i" -lt "${#args[@]}" ]; do
    case "${args[$i]}" in
      -c) deny "-c によるgit設定の一時上書きは実行できない" ;;
      -C | --git-dir | --work-tree | --namespace) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) sub="${args[$i]}"; rest=("${args[@]:$((i + 1))}"); break ;;
    esac
  done
  [ -z "$sub" ] && return 0
  allowed="${READ_GIT}"
  [ "${TRINITY_ROLE}" = generator ] && allowed="${READ_GIT}|${WRITE_GIT}"
  case "|${allowed}|" in
    *"|${sub}|"*) ;;
    *) deny "role=${TRINITY_ROLE} は git ${sub} を実行できない" ;;
  esac
  # commit は --amend / --no-verify を拒否する。-n を含む短い書き方もまとめて拒否する。
  [ "$sub" = commit ] && for t in "${rest[@]+"${rest[@]}"}"; do
    case "$t" in
      --amend | --no-verify) deny "git commit ${t} は実行できない" ;;
      --*) ;;
      -*n*) deny "git commit の -n（--no-verify）を含むフラグは実行できない" ;;
    esac
  done
  return 0
}

# コマンド文字列を引用符を考慮して単語 WORDS に分け、引用の外に演算子（& | ; ( ) ` と
# 行の折り返し \<改行>）があれば OPS=1 にする。引用の中は1つの単語として連結する。
scan() {
  local s="$1" c q cur="" have=0 i=0
  local n=${#s}
  WORDS=() OPS=0
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    case "$c" in
      "'" | '"')
        q="$c" have=1 i=$((i + 1))
        while [ "$i" -lt "$n" ] && [ "${s:$i:1}" != "$q" ]; do cur+="${s:$i:1}"; i=$((i + 1)); done
        i=$((i + 1)) ;;
      '\')
        if [ "${s:$((i + 1)):1}" = $'\n' ]; then OPS=1; else cur+="${s:$((i + 1)):1}" have=1; fi
        i=$((i + 2)) ;;
      '&' | '|' | ';' | '(' | ')' | '`') OPS=1; [ "$have" = 1 ] && WORDS+=("$cur"); cur="" have=0; i=$((i + 1)) ;;
      ' ' | $'\t' | $'\n' | $'\r') [ "$have" = 1 ] && WORDS+=("$cur"); cur="" have=0; i=$((i + 1)) ;;
      *) cur+="$c" have=1; i=$((i + 1)) ;;
    esac
  done
  [ "$have" = 1 ] && WORDS+=("$cur")
  return 0
}

# 先頭が git なら複合コマンドを拒否したうえで判定し、git が途中に現れる形（複合の後半・
# xargs git など）は安全に判定できないため拒否する。
check_bash() {
  scan "$1"
  local w
  if [ "${WORDS[0]:-}" = git ]; then
    [ "$OPS" = 1 ] && deny "git を含む複合コマンドは実行できない（単一の git コマンドに分ける）"
    check_git "${WORDS[@]:1}"
    return 0
  fi
  for w in "${WORDS[@]+"${WORDS[@]}"}"; do
    [ "$w" = git ] && deny "git を安全に判定できない形（複合・埋め込み）では実行できない"
  done
  return 0
}

raw="$(cat)"
case "$(field tool_name "$raw")" in
  Write | Edit) check_write "$(field file_path "$raw")" ;;
  NotebookEdit) check_write "$(field notebook_path "$raw")" ;;
  Bash)         check_bash "$(field command "$raw")" ;;
esac

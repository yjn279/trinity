#!/usr/bin/env bash
# scripts/guard.sh — アクターの役割境界を課す PreToolUse フック。許否の単一の正。
#
# stdin のフック JSON から tool_name / tool_input を読み、TRINITY_ROLE（planner / generator /
# evaluator）と RUN_DIR に応じて deny の JSON を返す（何も返さなければ許可）。git は許可
# サブコマンドの一覧で判定し（deny-by-default）、設定の書き込み・-c・git を含む複合コマンド
# （引用符の外の演算子・コマンド置換・行継続）は一覧に依らず deny する。
set -euo pipefail

TRINITY_ROLE="${TRINITY_ROLE:-}"

READ_GIT="log|show|diff|status|rev-parse|blame|cat-file|ls-files|ls-tree|for-each-ref|rev-list|describe|shortlog|show-ref|name-rev|grep|var|help|version|config"
WRITE_GIT="add|checkout|switch|restore|reset|revert|cherry-pick|merge|rebase|stash|mv|rm|clean|apply|branch|tag|notes|commit"

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# "KEY":"value" 形の文字列値を1つ抜き出し、JSON エスケープを実文字に戻す。
field() {
  local raw
  raw="$(printf '%s' "$2" | grep -Eo '"'"$1"'"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -1 \
    | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  raw="${raw//\\\\/$'\x01'}"; raw="${raw//\\n/$'\n'}"; raw="${raw//\\t/$'\t'}"
  raw="${raw//\\r/$'\r'}"; raw="${raw//\\\"/\"}"; raw="${raw//\\\///}"; raw="${raw//$'\x01'/\\}"
  printf '%s' "$raw"
}

in_list() { case "|$2|" in *"|$1|"*) return 0 ;; esac; return 1; }

# Write / Edit の書き込み範囲。evaluator は全面拒否、planner は RUN_DIR 内のみ、generator は
# 制約なし。planner のパスは正規化せず、境界を跨ぎうる「..」を一律 deny に倒す（fail-closed）。
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

# git config が読み取り専用形（--get 系・--list）かどうか。書き込み系フラグ、または
# 読み取りフラグ無しの位置引数形（alias 定義など）は false。
config_is_read() {
  local t read=1
  for t in "$@"; do
    case "$t" in
      --get | --get-all | --get-regexp | --get-urlmatch | --list | -l) read=0 ;;
      --add | --unset* | --replace-all | --rename-section | --remove-section | --edit | -e) return 1 ;;
    esac
  done
  return "$read"
}

# git の引数列を役割の一覧で判定する。-c は設定注入（core.pager 等のシェル実行）を許すため
# 一律 deny し、-C 等のリポジトリ指定フラグは値ごと読み飛ばしてサブコマンドを特定する。
check_git() {
  local sub="" i=0 t args=("$@") rest=()
  while [ "$i" -lt "${#args[@]}" ]; do
    case "${args[$i]}" in
      -c) deny "-c によるgit設定の一時上書きは実行できない" ;;
      -C | --git-dir | --work-tree | --namespace) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) sub="${args[$i]}"; rest=("${args[@]:$((i + 1))}"); break ;;
    esac
  done
  [ -z "$sub" ] && return 0
  local allowed="${READ_GIT}"
  [ "${TRINITY_ROLE}" = generator ] && allowed="${READ_GIT}|${WRITE_GIT}"
  in_list "$sub" "$allowed" || deny "role=${TRINITY_ROLE} は git ${sub} を実行できない"
  case "$sub" in
    config)
      config_is_read "${rest[@]+"${rest[@]}"}" || deny "git config の書き込み（alias 定義を含む）は実行できない" ;;
    commit)
      # --amend / --no-verify を deny する。-n を含む短縮フラグ束も丸ごと deny に倒す（fail-closed）。
      for t in "${rest[@]+"${rest[@]}"}"; do
        case "$t" in
          --amend | --no-verify) deny "git commit ${t} は実行できない" ;;
          --*) ;;
          -*n*) deny "git commit の -n（--no-verify）を含むフラグは実行できない" ;;
        esac
      done ;;
  esac
}

# command を引用符を考慮して語列 WORDS に分解し、引用の外の複合演算子（& | ; ( ) ` と
# 行継続 \<改行>）を見たら OPS=1 にする。引用の中はリテラルとして一語に連結する。
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
      '&' | '|' | ';' | '(' | ')' | '`')
        OPS=1; [ "$have" = 1 ] && WORDS+=("$cur"); cur="" have=0; i=$((i + 1)) ;;
      ' ' | $'\t' | $'\n' | $'\r')
        [ "$have" = 1 ] && WORDS+=("$cur"); cur="" have=0; i=$((i + 1)) ;;
      *) cur+="$c" have=1; i=$((i + 1)) ;;
    esac
  done
  [ "$have" = 1 ] && WORDS+=("$cur")
  return 0
}

# 実効コマンドが git なら複合を禁じたうえで check_git に渡し、git が語として他所に現れる形
# （複合の後半・xargs git 等）は安全に判定できないため deny する。
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

#!/usr/bin/env bash
# scripts/guard.sh — 各役割の権限を制限するフック（PreToolUse）。許可・拒否の判断はここが正。
# フックの JSON からツール名と引数を読み、役割（TRINITY_ROLE）に応じて拒否の JSON を返す
# （何も返さなければ許可）。git を含むコマンドは、判定できる単純な形（展開なし・引用符は
# 一種類・先頭の単一コマンド）だけを許し、判定できない形は書き直しを求めて拒否する。
set -euo pipefail

TRINITY_ROLE="${TRINITY_ROLE:-}"

deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# JSON から "KEY":"値" の値を取り出す。エスケープ（\" や \n）は戻さず、1行のまま返す。
field() {
  grep -Eo '"'"$1"'"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' <<<"$2" | head -1 |
    sed -E 's/^[^:]*:[[:space:]]*"//; s/"$//'
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

# git の引数を判定する。設定の変更（-c）は別名の定義やコマンド実行を仕込めるため役割によらず
# 拒否し、-C などの場所指定は値ごと読み飛ばしてサブコマンドを探す。サブコマンドは許可一覧
# （deny-by-default）で決め、読み取りは全役割に、変更は generator だけに許す。
check_git() {
  local args=("$@") sub="" i=0 t
  while [ "$i" -lt "$#" ]; do
    case "${args[$i]}" in
      -c) deny "-c によるgit設定の一時上書きは実行できない" ;;
      -C | --git-dir | --work-tree | --namespace) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) sub="${args[$i]}"; break ;;
    esac
  done
  [ -n "$sub" ] || return 0
  case "${TRINITY_ROLE}:${sub}" in
    *:log | *:show | *:diff | *:status | *:blame | *:grep | *:rev-parse | *:rev-list | *:ls-files | *:describe) ;;
    generator:add | generator:rm | generator:mv | generator:restore | generator:checkout | generator:switch | generator:reset | generator:stash | generator:commit) ;;
    *) deny "role=${TRINITY_ROLE} は git ${sub} を実行できない" ;;
  esac
  [ "$sub" = commit ] || return 0
  for t in "${args[@]}"; do
    case "$t" in
      --amend | --no-verify) deny "git commit ${t} は実行できない" ;;
      --*) ;;
      -*n*) deny "git commit の -n（--no-verify）を含むフラグは実行できない" ;;
    esac
  done
}

# Bash の command を判定する。引用符とバックスラッシュを除いても git という並びが現れない
# コマンドは対象外として許可する。git を含むコマンドは、判定を狂わせる形（バックスラッシュ・
# 変数や置換の展開・引用符の混在・語の一部だけの引用）を拒否したうえで引用部分を1語に畳み、
# 区切り文字が残れば複合コマンドとして拒否し、残った語を単一の git コマンドとして判定する。
# 作業場所の変数だけは値に置き換える。引用の中身や別コマンド経由の間接実行までは追わない。
check_bash() {
  local s="$1" g w q=$'\x01'
  g="${s//\\/}"; g="${g//\'/}"; g="${g//\"/}"
  case "$g" in *git*) ;; *) return 0 ;; esac
  s="${s//\$\{WORKTREE_DIR\}/${WORKTREE_DIR:-}}"
  s="${s//\$WORKTREE_DIR/${WORKTREE_DIR:-}}"
  [[ "$s" == *'\\'* ]] && deny "git を含むコマンドにバックスラッシュがあると判定できない（使わない形に書き直す）"
  [[ "$s" == *'$'* || "$s" == *'`'* ]] && deny "git を含むコマンドで変数や置換の展開は判定できない（WORKTREE_DIR 以外は値を直接書く）"
  [[ "$s" == *\'* && "$s" == *'\"'* ]] && deny "git を含むコマンドで引用符の混在は判定できない（一種類に揃える）"
  s="${s//\\n/;}"; s="${s//\\r/;}"; s="${s//\\t/ }"
  s="$(sed -E 's/\\"[^\\]*\\"/'"$q"'/g; s/'\''[^'\'']*'\''/'"$q"'/g; s/^[[:space:];]+//; s/[[:space:];]+$//' <<<"$s")"
  [[ "$s" == *\\* || "$s" == *\'* ]] && deny "git を含むコマンドの引用符が閉じていない"
  local IFS=$' \t&|;()<>' seen=0
  set -f
  # shellcheck disable=SC2086
  set -- $s
  set +f
  for w in "$@"; do
    [[ "$w" == *"$q"* && "$w" != "$q" ]] && deny "git を含むコマンドで語の一部だけの引用は判定できない（語全体を引用するか外す）"
    [[ "$w" == git || "$w" == */git ]] && seen=1
  done
  [ "$seen" = 1 ] || return 0
  [ "${1:-}" = git ] || deny "git は先頭の単独コマンドとしてだけ実行できる"
  [[ "$s" == *[\&\|\;\(\)\<\>]* ]] && deny "git を含む複合コマンドや入出力の付け替えは実行できない（1つの git コマンドに分ける）"
  shift
  check_git "$@"
}

raw="$(cat)"
case "$(field tool_name "$raw")" in
  Write | Edit) check_write "$(field file_path "$raw")" ;;
  NotebookEdit) check_write "$(field notebook_path "$raw")" ;;
  Bash)         check_bash "$(field command "$raw")" ;;
esac

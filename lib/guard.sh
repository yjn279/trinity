#!/usr/bin/env bash
# lib/guard.sh — Trinity アクター用の PreToolUse ガードフック。
#
# `claude -p` 子プロセスへ per-role の役割境界を「プロンプトの約束」ではなく機構として課す。
# stdin から PreToolUse フックの JSON（`tool_name`/`tool_input` を含む）を受け取り、環境変数
# TRINITY_ROLE（planner/generator/evaluator）と RUN_DIR を読んで、Claude Code のフック仕様
# （`hookSpecificOutput.permissionDecision`）に沿って allow/deny を stdout の JSON で返す。
# 判断基準そのもの（誰が何を拒否されるか）は plan.md の役割プロファイルを機構化したものであり、
# 振る舞いの単一の正である agents/<role>.md の記述と矛盾しない。
#
# ハーネスの正準形は `git -C "${WORKTREE_DIR}" <cmd>`（worktree 隔離）であり、フラグのプレ
# フィックス照合ではこれを回避できない。よってコマンドを意味解析し、`-C <dir>` や
# `--git-dir=` を読み飛ばしてサブコマンドを抽出したうえで役割ごとの許否集合と照合する。
#
# 想定脅威は「指示を取り違えた LLM のドリフト」であり、意図的な難読化への完全防御はしない
# （plan.md Non-Goals）。依存追加は避け、bash/grep/sed の最小限の手段で完結させる。
set -euo pipefail

# guard::json_field KEY JSON — "KEY":"value" 形の文字列値を1つ抜き出す（最小限のJSONパーサ）。
# JSON エスケープ（\" や \\）を跨いで値の終端を誤検出しないよう ([^"\\]|\\.)* で1トークン化する。
guard::json_field() {
  local key="$1" json="$2"
  printf '%s' "$json" \
    | grep -Eo '"'"$key"'"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' \
    | head -1 \
    | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//'
}

# guard::deny REASON — deny 決定のJSONを標準出力へ書き、スクリプトを正常終了する。
guard::deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# guard::split_segments COMMAND — ; && || | で連結されたコマンド文字列を1コマンドずつへ分割する。
# 長い区切り（|| / &&）を単一の | より先に処理し、連結記号の誤爆を避ける。
# 出力は必ず末尾改行を持たせる（`while read` が最終行を読み飛ばすのを防ぐ）。
guard::split_segments() {
  printf '%s\n' "$1" | sed -e 's/||/\n/g' -e 's/&&/\n/g' -e 's/;/\n/g' -e 's/|/\n/g'
}

# guard::git_subcommand TOKENS... — `git` コマンドのサブコマンドを抽出する。
# -C <dir> / -c <k=v> / --git-dir=... / --work-tree=... 等のフラグを読み飛ばし、
# `git -C <dir> <sub>` 形をフラグのプレフィックス照合の弱点を回避して捕捉する。
# 成功時は stdout へ "サブコマンド<TAB>残り引数" を1行返す（git コマンドでなければ非0を返す）。
guard::git_subcommand() {
  [ "$#" -ge 1 ] && [ "$1" = "git" ] || return 1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C|-c) shift 2 2>/dev/null || return 1 ;;
      -*) shift ;;
      *) printf '%s\t%s\n' "$1" "${*:2}"; return 0 ;;
    esac
  done
  return 1
}

# guard::is_mutating_git SUB — planner/evaluator が拒否する状態変更 git のサブコマンド集合。
guard::is_mutating_git() {
  case "$1" in
    commit|push|reset|rebase|merge|checkout|switch|tag|branch|cherry-pick|revert|stash|am|apply|gc|filter-branch|update-ref)
      return 0 ;;
    *) return 1 ;;
  esac
}

# guard::check_bash ROLE COMMAND — Bash ツールの git コマンドを意味解析し、役割プロファイルに
# 反していれば deny する。cd <dir> && git ... の形は連結分割後、cd 側の segment が
# git_subcommand で非git判定（continue）となり、git 側 segment だけが評価される。
guard::check_bash() {
  local role="$1" command="$2" segment result sub rest
  while IFS= read -r segment || [ -n "$segment" ]; do
    set -f
    # shellcheck disable=SC2086
    set -- $segment
    set +f
    result="$(guard::git_subcommand "$@")" || continue
    IFS=$'\t' read -r sub rest <<< "$result"
    case "$role" in
      planner|evaluator)
        if guard::is_mutating_git "$sub"; then
          guard::deny "role=${role} は状態変更 git（${sub}）を実行できない"
        fi
        ;;
      generator)
        case "$sub" in
          push)
            guard::deny "role=generator は push を実行できない（push はオーケストレーターの責務）"
            ;;
          commit)
            case " ${rest} " in
              *' --amend '*|*' --no-verify '*)
                guard::deny "role=generator は git commit --amend / --no-verify を実行できない"
                ;;
            esac
            ;;
        esac
        ;;
    esac
  done < <(guard::split_segments "$command")
}

# guard::check_write ROLE FILE_PATH — Write/Edit の file_path 制約を判定する。
# evaluator は読み取り専用として全面拒否、planner は RUN_DIR 内のみ許可、generator は制約なし。
guard::check_write() {
  local role="$1" file_path="$2" run_dir
  case "$role" in
    evaluator)
      guard::deny "role=evaluator は読み取り専用でありWrite/Editを実行できない"
      ;;
    planner)
      run_dir="${RUN_DIR:-}"
      run_dir="${run_dir%/}"
      case "$file_path" in
        "${run_dir}"|"${run_dir}"/*) : ;;
        *)
          guard::deny "role=plannerはRUN_DIR外への書き込みができない: ${file_path}"
          ;;
      esac
      ;;
  esac
}

main() {
  local raw role tool_name
  raw="$(cat)"
  role="${TRINITY_ROLE:-}"
  tool_name="$(guard::json_field tool_name "$raw")"
  case "$tool_name" in
    Bash)
      guard::check_bash "$role" "$(guard::json_field command "$raw")"
      ;;
    Write|Edit)
      guard::check_write "$role" "$(guard::json_field file_path "$raw")"
      ;;
  esac
}

main

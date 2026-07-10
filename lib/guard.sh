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
# JSON エスケープ（\" や \\）を跨いで値の終端を誤検出しないよう ([^"\\]|\\.)* で1トークン化し、
# 抜き出した生トークンは guard::json_unescape でデコードしてから返す（抽出とデコードの責務を分離）。
guard::json_field() {
  local key="$1" json="$2" raw
  raw="$(printf '%s' "$json" \
    | grep -Eo '"'"$key"'"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' \
    | head -1 \
    | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  guard::json_unescape "$raw"
}

# guard::json_unescape STRING — JSON文字列エスケープ（\n \t \r \" \/ \\）を実文字へ復元する。
# \\ は先にプレースホルダへ退避してから他のエスケープを展開し、最後に単一の \ へ戻すことで、
# 元の文字列に含まれていた素の \ を誤ってエスケープシーケンスとして再解釈しないようにする。
# 例えばコマンド中の物理改行はJSON化の際 \n（バックスラッシュ+n の2文字）に変換されるため、
# これをデコードしないと guard::split_segments に渡る文字列に実改行が現れず分割対象から漏れる。
guard::json_unescape() {
  local s="$1"
  s="${s//\\\\/$'\x01'}"
  s="${s//\\n/$'\n'}"
  s="${s//\\t/$'\t'}"
  s="${s//\\r/$'\r'}"
  s="${s//\\\"/\"}"
  s="${s//\\\///}"
  s="${s//$'\x01'/\\}"
  printf '%s' "$s"
}

# guard::deny REASON — deny 決定のJSONを標準出力へ書き、スクリプトを正常終了する。
guard::deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

# guard::split_segments COMMAND — ; && || | および物理改行で連結されたコマンド文字列を
# 1コマンドずつへ分割する。長い区切り（|| / &&）を単一の | より先に処理し、連結記号の誤爆を
# 避ける。\r は \n に正規化してから渡すため、guard::json_unescape が復元した実改行（LLM が
# 1回のBash呼び出しで複数コマンドを改行区切りで書く典型パターン）も呼び出し側の `while read -r`
# が1行＝1セグメントとして確実に読み取れる。
# 出力は必ず末尾改行を持たせる（`while read` が最終行を読み飛ばすのを防ぐ）。
guard::split_segments() {
  printf '%s\n' "$1" | sed -e 's/\r/\n/g' -e 's/||/\n/g' -e 's/&&/\n/g' -e 's/;/\n/g' -e 's/|/\n/g'
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

# guard::normalize_path PATH — "." "/" の連続や ".." を解決した正規パスを返す（依存追加を避け、
# ファイル非存在でも解決できるよう `realpath` は使わず bash 文字列処理のみで完結させる）。
# 絶対パス（先頭 "/"）では ".." がルートを超えて遡らないようにし、相対パスではそのまま残す。
guard::normalize_path() {
  local path="$1" component rest result="" abs=0
  [ "${path:0:1}" = "/" ] && abs=1
  rest="$path"
  while [ -n "$rest" ]; do
    component="${rest%%/*}"
    if [ "$component" = "$rest" ]; then
      rest=""
    else
      rest="${rest#*/}"
    fi
    case "$component" in
      ''|'.') continue ;;
      '..')
        if [ -n "$result" ]; then
          case "$result" in
            ..|*/..) result="${result}/.." ;;
            */*) result="${result%/*}" ;;
            *) result="" ;;
          esac
        elif [ "$abs" -eq 0 ]; then
          result=".."
        fi
        ;;
      *)
        if [ -z "$result" ]; then
          result="$component"
        else
          result="${result}/${component}"
        fi
        ;;
    esac
  done
  if [ "$abs" -eq 1 ]; then
    printf '/%s' "$result"
  else
    printf '%s' "$result"
  fi
}

# guard::check_write ROLE FILE_PATH — Write/Edit の file_path 制約を判定する。
# evaluator は読み取り専用として全面拒否、planner は RUN_DIR 内のみ許可、generator は制約なし。
# RUN_DIR 包含判定は文字列プレフィックス一致だけだと "${RUN_DIR}/../outside.sh" のような ".."
# を含む脱出を見逃すため、判定前に guard::normalize_path で双方を正規化する。
guard::check_write() {
  local role="$1" file_path="$2" run_dir normalized_path normalized_run_dir
  case "$role" in
    evaluator)
      guard::deny "role=evaluator は読み取り専用でありWrite/Editを実行できない"
      ;;
    planner)
      run_dir="${RUN_DIR:-}"
      normalized_run_dir="$(guard::normalize_path "${run_dir%/}")"
      normalized_path="$(guard::normalize_path "$file_path")"
      case "$normalized_path" in
        "${normalized_run_dir}"|"${normalized_run_dir}"/*) : ;;
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

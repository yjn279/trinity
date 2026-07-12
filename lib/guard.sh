#!/usr/bin/env bash
# lib/guard.sh — Trinity アクター用の PreToolUse ガードフック（Write/Edit 専用）。
#
# `claude -p` 子プロセスへ per-role の役割境界を「プロンプトの約束」ではなく機構として課す。
# stdin から PreToolUse フックの JSON（`tool_name`/`tool_input` を含む）を受け取り、環境変数
# TRINITY_ROLE（planner/generator/evaluator）と RUN_DIR を読んで、Claude Code のフック仕様
# （`hookSpecificOutput.permissionDecision`）に沿って allow/deny を stdout の JSON で返す。
# 判断基準そのもの（誰が何を拒否されるか）は plan.md の役割プロファイルを機構化したものであり、
# 振る舞いの単一の正である agents/<role>.md の記述と矛盾しない。
#
# git の役割境界は PATH レベルの shim（lib/git-shim/git）が exec 時点の argv で enforce する
# （trinity::claude が子の PATH 先頭へ prepend）。git のプロファイル（状態変更集合・generator
# 例外）は shim 内の一箇所のみが正であり、本ファイルへは書き写さない。本ファイルは
# Write/Edit（サブプロセスを経由しないファイル書き込み）のみを扱う。
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
# 例えば file_path 中の物理改行はJSON化の際 \n（バックスラッシュ+n の2文字）に変換されるため、
# これをデコードしないと判定対象の文字列に実改行が現れず一致判定を誤る。
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

# guard::normalize_path PATH — "." "/" の連続や ".." を解決した絶対パスを返す（依存追加を避け、
# ファイル非存在でも解決できるよう `realpath` は使わず bash 文字列処理のみで完結させる）。
# 呼び出し元（RUN_DIR・Write/Edit/NotebookEdit の file_path/notebook_path）は常に絶対パスのため、
# ルートを超える ".." は無視する。
guard::normalize_path() {
  local path="$1" component rest result=""
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
        case "$result" in
          ..|*/..) result="${result}/.." ;;
          */*) result="${result%/*}" ;;
          *) result="" ;;
        esac
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
  printf '/%s' "$result"
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
      # RUN_DIR 未設定・空のまま境界判定に使うと正規化結果が "" になり、後続の case が
      # "starts with /" と等価になって全ての絶対パスを許可してしまう（fail-open）。
      # 判定不能な状態は allow ではなく deny 側に倒す。
      [ -n "$run_dir" ] || guard::deny "role=plannerはRUN_DIR未設定のため書き込み範囲を判定できない"
      normalized_run_dir="$(guard::normalize_path "${run_dir%/}")"
      normalized_path="$(guard::normalize_path "$file_path")"
      case "$normalized_path" in
        "${normalized_run_dir}"|"${normalized_run_dir}"/*) : ;;
        *)
          guard::deny "role=plannerはRUN_DIR外への書き込みができない: ${file_path}"
          ;;
      esac
      ;;
    generator)
      : # 制約なし。
      ;;
    *)
      guard::deny "role未知（TRINITY_ROLE=${role}）のためWrite/Editを実行できない"
      ;;
  esac
}

main() {
  local raw role tool_name
  raw="$(cat)"
  role="${TRINITY_ROLE:-}"
  tool_name="$(guard::json_field tool_name "$raw")"
  case "$tool_name" in
    Write|Edit)
      guard::check_write "$role" "$(guard::json_field file_path "$raw")"
      ;;
    NotebookEdit)
      guard::check_write "$role" "$(guard::json_field notebook_path "$raw")"
      ;;
  esac
}

main

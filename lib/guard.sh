#!/usr/bin/env bash
# lib/guard.sh — Trinity アクター用の PreToolUse ガードフック（Write/Edit と Bash の git）。
#
# `claude -p` 子プロセスへ per-role の役割境界を「プロンプトの約束」ではなく機構として課す。
# stdin から PreToolUse フックの JSON（`tool_name`/`tool_input` を含む）を受け取り、環境変数
# TRINITY_ROLE（planner/generator/evaluator）と RUN_DIR を読んで、Claude Code のフック仕様
# （`hookSpecificOutput.permissionDecision`）に沿って allow/deny を stdout の JSON で返す。
# 判断基準そのもの（誰が何を拒否されるか）は plan.md の役割プロファイルを機構化したものであり、
# 振る舞いの単一の正である agents/<role>.md の記述と矛盾しない。
#
# 役割境界はこのフック一本で enforce する。Write/Edit/NotebookEdit はファイル書き込みの範囲を、
# Bash は `tool_input.command` を分解して git の役割別ポリシーを判定する。このフックは allow/deny を
# 返すだけで git を自ら exec しないため、「検査器が git を呼び、その git がまた検査器を呼ぶ」相互再入
# （fork リーク）が構造的に起こり得ない。
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

# ── Bash の git 検査 ─────────────────────────────────────────────────────────
# TRINITY_ROLE の許否集合はここが単一の正であり、agents/*.md へ書き写さない。
# 状態変更禁止ロール（planner/evaluator）は「読み取り専用サブコマンドの allowlist」
# （deny-by-default）へ倒し、alias 名を含む allowlist 外の語をすべて拒否する。
# generator は広く git を要するため denylist を維持しつつ、alias 経由の迂回だけを個別に塞ぐ。

# guard::git_bin — 検査に使う本物の git を、汚染されうる PATH に依存せず絶対パスで解決する。
# 実体の git を優先し、xcrun 経由の /usr/bin/git スタブは最後に回す（環境隔離下でも確実に動く）。
guard::git_bin() {
  local d
  for d in /opt/homebrew/bin /usr/local/bin /usr/bin /bin; do
    [ -x "${d}/git" ] && { printf '%s' "${d}/git"; return 0; }
  done
  return 1
}

# guard::git_query ARGS... — 検査専用に本物の git を環境隔離して実行する。
# env -i で PATH と GIT_* を落とし（PATH に何が積まれても検査器へ再入しない）、
# HOME だけ残して対象リポジトリと利用者グローバルの alias を解決できる範囲に保つ。
guard::git_query() {
  local gitbin
  gitbin="$(guard::git_bin)" || return 1
  env -i PATH=/usr/bin HOME="${HOME:-}" "$gitbin" "$@"
}

# guard::git_config_is_read ARGS... — git config 呼び出しが読み取り専用形（--get/--get-all/
# --get-regexp/--get-urlmatch/--list/-l）かどうかを判定する。書き込み系フラグが含まれる場合や
# 読み取りフラグが1つも無い場合（`git config alias.p '...'` のような位置引数形の代入）は false。
guard::git_config_is_read() {
  local tok found_read=0
  for tok in "$@"; do
    case "$tok" in
      --get | --get-all | --get-regexp | --get-urlmatch | --list | -l)
        found_read=1
        ;;
      --add | --unset | --unset-all | --replace-all | --rename-section | --remove-section | --edit | -e)
        return 1
        ;;
    esac
  done
  [ "$found_read" -eq 1 ]
}

# guard::git_strip_quotes TOKEN — 前後を囲む一重の引用符（"..." または '...'）を1組だけ剥がす。
# alias 展開はスペース区切りの argv 列として素朴に分割するため、`commit "--amend"` のような
# 引用符付きの値は分割後も引用符が残る。しかし本物 git 自身の alias 展開はこの引用符を剥がして
# フラグとして解釈するため、剥がさずに比較すると `--amend` が字面一致せず判定を素通りする。
guard::git_strip_quotes() {
  local t="$1"
  case "$t" in
    \"*\") t="${t#\"}"; t="${t%\"}" ;;
    \'*\') t="${t#\'}"; t="${t%\'}" ;;
  esac
  printf '%s' "$t"
}

# guard::git_is_denied_commit_flag TOKEN — commit のトークンが --amend/--no-verify 相当か判定する。
# git は commit の真偽値の短縮オプション（-n など）を1トークンへ束ねられる（例: -na は -n -a）。
# 値を取る短縮オプション（-m/-c/-C/-F/-t/-S/-u）以降の文字は値なので、そこで走査を止める。
guard::git_is_denied_commit_flag() {
  local tok="$1"
  case "$tok" in
    --amend | --no-verify) return 0 ;;
    --*) return 1 ;;
    -*)
      local body="${tok#-}" i=0 c
      local len=${#body}
      while [ "$i" -lt "$len" ]; do
        c="${body:$i:1}"
        case "$c" in
          n) return 0 ;;
          m | c | C | F | t | S | u) return 1 ;;
        esac
        i=$((i + 1))
      done
      return 1
      ;;
    *) return 1 ;;
  esac
}

# guard::git_deny_if_commit_flags MESSAGE ARGS... — commit のトークン列に --amend/--no-verify
# 相当が1つでもあれば MESSAGE で deny する。直接呼び出しと alias 展開の両方の commit 判定が使う共通経路。
guard::git_deny_if_commit_flags() {
  local message="$1" a
  shift
  for a in "$@"; do
    guard::git_is_denied_commit_flag "$a" && guard::deny "$message"
  done
  return 0
}

# guard::check_alias_chain ROLE NAME DEPTH — 本物 git の既存 alias 定義（`config alias.<NAME>`）を
# 解決し、shell alias（`!` 始まり）や push・commit --amend/--no-verify へ展開されるなら deny する。
# alias が別の alias 名へ展開されるケースに備え再帰するが、深さ制限で無限ループを防ぐ。git は同名の
# 組み込みサブコマンドを常に alias より優先するため、NAME が allowlist/組み込み名と衝突する場合は
# そもそも alias 展開が使われず安全側に倒れる。alias は対象リポジトリの設定であり、呼び出し元の argv
# から抽出した -C/--git-dir/--work-tree/--namespace（GUARD_GIT_REPO_CTX）を前置して解決する。
# 再帰は同一プロセス内の関数呼び出しで完結する（フックは git を自ら exec せず子プロセスへ再入
# しない）ため、深さ引数だけで 5 段制限を担保する。
guard::check_alias_chain() {
  local role="$1" name="$2" depth="${3:-0}" expansion first a
  [ -z "$name" ] && return 0
  # 深さ上限に達しても「解決できなかった」だけであり安全は確認できていないため、
  # allow ではなく deny 側に倒す（fail-open による push/amend 迂回を防ぐ）。
  [ "$depth" -ge 5 ] && guard::deny "role=${role} は alias 展開の連鎖が深すぎて安全性を確認できない（${name}）"
  # git 本体を解決できなければ alias が push/shell へ展開されるか確認できない。安全は確認できて
  # いないので、代替値で先へ進めず（fail-open 防止）その場で deny する。
  guard::git_bin >/dev/null 2>&1 \
    || guard::deny "role=${role} は git を解決できず alias（${name}）の安全性を確認できない"
  expansion="$(guard::git_query "${GUARD_GIT_REPO_CTX[@]+"${GUARD_GIT_REPO_CTX[@]}"}" config --get "alias.${name}" 2>/dev/null || true)"
  [ -z "$expansion" ] && return 0
  case "$expansion" in
    '!'*)
      guard::deny "role=${role} はシェル実行を伴う git alias（${name} → ${expansion}）を実行できない"
      ;;
  esac
  # alias 展開はスペース区切りの git 引数列として意図的に分割する。
  # shellcheck disable=SC2206
  local -a exp_args=($expansion)
  first="$(guard::git_strip_quotes "${exp_args[0]:-}")"
  case "$first" in
    push)
      guard::deny "role=${role} は push へ展開される git alias（${name} → ${expansion}）を実行できない"
      ;;
    commit)
      local -a stripped_args=()
      for a in "${exp_args[@]:1}"; do
        stripped_args+=("$(guard::git_strip_quotes "$a")")
      done
      guard::git_deny_if_commit_flags \
        "role=${role} は commit --amend/--no-verify へ展開される git alias（${name} → ${expansion}）を実行できない" \
        "${stripped_args[@]+"${stripped_args[@]}"}"
      ;;
  esac
  guard::check_alias_chain "$role" "$first" "$((depth + 1))"
}

# guard::check_git ROLE ARGS... — git の引数列（`git` の後ろ）を role 別の規約で判定する。
# 先頭のオプションを読み飛ばしてサブコマンドを特定し、-c は全ロール一律で deny する
# （core.fsmonitor/core.pager/core.sshCommand 注入対策）。repo_ctx は alias 解決へ引き渡す。
guard::check_git() {
  local role="$1"; shift
  local sub="" i=0 tok
  local -a args=("$@") rest=()
  GUARD_GIT_REPO_CTX=()
  while [ "$i" -lt "${#args[@]}" ]; do
    tok="${args[$i]}"
    case "$tok" in
      -c)
        # -c <key>=<value> は本物 git への委譲後にそのプロセス内だけで設定を一時上書きし、
        # alias.* によるサブコマンド名の完全一致判定の迂回や、core.pager・core.fsmonitor・
        # core.sshCommand のようなシェル実行を伴う設定キーへの注入を許してしまう。
        # どのアクターも -c による一時上書きを正当に必要としないため、キーを問わず一律で deny する。
        guard::deny "role=${role} は -c によるgit設定の一時上書きを実行できない"
        ;;
      -C | --git-dir | --work-tree | --namespace)
        GUARD_GIT_REPO_CTX+=("$tok" "${args[$((i + 1))]:-}")
        i=$((i + 2))
        ;;
      --git-dir=* | --work-tree=* | --namespace=*)
        GUARD_GIT_REPO_CTX+=("$tok")
        i=$((i + 1))
        ;;
      -*) i=$((i + 1)) ;;
      *)
        sub="$tok"
        rest=("${args[@]:$((i + 1))}")
        break
        ;;
    esac
  done

  case "$role" in
    planner | evaluator)
      case "$sub" in
        config)
          guard::git_config_is_read "${rest[@]+"${rest[@]}"}" ||
            guard::deny "role=${role} は git config の書き込み操作を実行できない"
          ;;
        "" | log | show | diff | status | rev-parse | blame | cat-file | ls-files | ls-tree | for-each-ref | rev-list | describe | shortlog | show-ref | name-rev | grep | var | help | version)
          : # 読み取り専用サブコマンドの allowlist。ここに無い語（alias 名・両用コマンド・
            # 未知/将来のサブコマンドを含む）はすべて deny-by-default で拒否する。
          ;;
        *)
          guard::deny "role=${role} は読み取り専用の git サブコマンド以外（${sub}）を実行できない"
          ;;
      esac
      ;;
    generator)
      case "$sub" in
        push)
          guard::deny "role=${role} は push を実行できない（push はオーケストレーターの責務）"
          ;;
        commit)
          guard::git_deny_if_commit_flags \
            "role=${role} は git commit --amend / --no-verify を実行できない" \
            "${rest[@]+"${rest[@]}"}"
          ;;
        config)
          guard::git_config_is_read "${rest[@]+"${rest[@]}"}" ||
            guard::deny "role=${role} は git config の書き込み操作を実行できない（alias 定義を含む）"
          ;;
      esac
      # サブコマンド名が本物 git 側に既存の alias として定義されていないか解決し、
      # push・shell alias・commit --amend/--no-verify への展開を deny する。
      guard::check_alias_chain "$role" "$sub" 0
      ;;
    *)
      guard::deny "role=${role} は未知のロールのため git を実行できない"
      ;;
  esac
}

# guard::_flush_word — 収集中の語があれば GUARD_TOKENS へ確定する（guard::tokenize 専用）。
guard::_flush_word() {
  if [ "${GUARD_TOK_HAVE}" -eq 1 ]; then
    GUARD_TOKENS+=("W:${GUARD_TOK_CUR}")
    GUARD_TOK_CUR=""; GUARD_TOK_HAVE=0
  fi
}

# guard::tokenize COMMAND — シェル文字列を語（word）とコマンド境界の列へ分解し、グローバル配列
# GUARD_TOKENS へ "W:<語>"（クォート除去済み）/ "O"（境界）で積む。目的は「git で始まる単純コマンド」を
# 境界で切り出すことに尽き、完全なシェル文法の再現ではない。引用符内はリテラルとして一語に連結し境界を
# 作らない（`-m "wip; done"` の中の区切り文字を誤って境界にしない）。無引用の & | ; ( ) ` と改行を境界と
# して扱い、コマンド置換 `$(...)` やバッククォートの内側 git は ( ) ` が作る境界で独立コマンドとして拾う。
# 自然な git 呼び出しの形を対象とし、二重引用符内へ隠したコマンド置換のような難読化までは追わない
# （deny-by-default と false-positive の低コストでこの割り切りを受け入れる）。
guard::tokenize() {
  local s="$1" n c q
  local -i i=0
  n=${#s}
  GUARD_TOKENS=()
  GUARD_TOK_CUR=""; GUARD_TOK_HAVE=0
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    case "$c" in
      "'" | '"')
        q="$c"; GUARD_TOK_HAVE=1; i=$((i + 1))
        while [ "$i" -lt "$n" ] && [ "${s:$i:1}" != "$q" ]; do
          GUARD_TOK_CUR="${GUARD_TOK_CUR}${s:$i:1}"; i=$((i + 1))
        done
        i=$((i + 1))
        ;;
      '\')
        if [ "$((i + 1))" -ge "$n" ]; then
          i=$((i + 1))
        elif [ "${s:$((i + 1)):1}" = $'\n' ]; then
          i=$((i + 2))   # 行継続（\<改行>）はシェルが除去する。語に含めず次語と繋げない。
        else
          GUARD_TOK_CUR="${GUARD_TOK_CUR}${s:$((i + 1)):1}"; GUARD_TOK_HAVE=1; i=$((i + 2))
        fi
        ;;
      '`' | '&' | '|' | ';' | '(' | ')' | $'\n' | $'\r')
        guard::_flush_word; GUARD_TOKENS+=("O"); i=$((i + 1))
        ;;
      ' ' | $'\t')
        guard::_flush_word; i=$((i + 1))
        ;;
      *)
        GUARD_TOK_CUR="${GUARD_TOK_CUR}${c}"; GUARD_TOK_HAVE=1; i=$((i + 1))
        ;;
    esac
  done
  guard::_flush_word
}

# guard::check_bash ROLE COMMAND — Bash tool の command を分解し、各 git 単純コマンドを検査する。
# 先頭の VAR=val 代入（`GIT_COMMITTER_DATE=... git commit` 等）と env は読み飛ばし、コマンド名が git の
# とき後続の引数を境界まで集めて guard::check_git に渡す。git 以外のコマンドは境界まで無視する。
guard::check_bash() {
  local role="$1" command="$2" tok val
  guard::tokenize "$command"
  local -i at_cmd_start=1 in_git=0
  local -a gitargs=()
  for tok in "${GUARD_TOKENS[@]+"${GUARD_TOKENS[@]}"}"; do
    if [ "$tok" = "O" ]; then
      if [ "$in_git" -eq 1 ]; then
        guard::check_git "$role" "${gitargs[@]+"${gitargs[@]}"}"
        in_git=0; gitargs=()
      fi
      at_cmd_start=1; continue
    fi
    val="${tok#W:}"
    if [ "$in_git" -eq 1 ]; then
      gitargs+=("$val"); continue
    fi
    if [ "$at_cmd_start" -eq 1 ]; then
      case "$val" in
        *=* | env) : ;;                             # 先頭の VAR=val 代入と env は読み飛ばす。
        git) in_git=1; at_cmd_start=0 ;;
        *) at_cmd_start=0 ;;                         # git 以外のコマンド。境界まで無視する。
      esac
    fi
  done
  if [ "$in_git" -eq 1 ]; then
    guard::check_git "$role" "${gitargs[@]+"${gitargs[@]}"}"
  fi
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
    Bash)
      guard::check_bash "$role" "$(guard::json_field command "$raw")"
      ;;
  esac
}

main

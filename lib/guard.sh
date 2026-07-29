#!/usr/bin/env bash
# lib/guard.sh — Trinity アクター用の PreToolUse ガードフック（Write/Edit と Bash の git）。
#
# `claude -p` 子プロセスへ per-role の役割境界を「プロンプトの約束」ではなく機構として課す。
# stdin から PreToolUse フックの JSON（`tool_name`/`tool_input` を含む）を受け取り、環境変数
# TRINITY_ROLE（planner/generator/evaluator）と RUN_DIR を読んで、Claude Code のフック仕様
# （`hookSpecificOutput.permissionDecision`）に沿って allow/deny を stdout の JSON で返す。
# 判断基準そのもの（誰が何を拒否されるか）はこのファイルが単一の正であり、
# 振る舞いの単一の正である agents/<role>.md の記述と矛盾しない。
#
# 役割境界はこのフック一本で enforce する。Write/Edit/NotebookEdit はファイル書き込みの範囲を、
# Bash は `tool_input.command` から git の役割別ポリシーを判定する。git は許可サブコマンドの
# allowlist（deny-by-default）で判定し、状態を変える evasion（alias 追加・設定注入）は config 書き込みと
# `-c` を deny することで閉じる。git を含む複合コマンド（演算子・コマンド置換・行継続）は、git 呼び出しを
# 安全に切り出せないため deny し、単一の git コマンドへ分けさせる。このフックは allow/deny を返すだけで
# git を自ら exec しないため、検査のために別の git を spawn する相互再入（fork リーク）が起こり得ない。
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
# TRINITY_ROLE の許否集合はここが単一の正であり、agents/*.md へ書き写さない。すべてのロールを
# allowlist（deny-by-default）で判定する。planner/evaluator は読み取り専用サブコマンド、generator は
# それに worktree 内で状態を変えるサブコマンドを加える。allowlist 外の語（未知/将来のサブコマンド・
# alias 名を含む）はすべて deny する。alias によるカスタム名は allowlist に無く、config 書き込みも
# deny するため、runtime で alias を展開して追う必要はない。

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
# 相当が1つでもあれば MESSAGE で deny する。
guard::git_deny_if_commit_flags() {
  local message="$1" a
  shift
  for a in "$@"; do
    guard::git_is_denied_commit_flag "$a" && guard::deny "$message"
  done
  return 0
}

# guard::check_git ROLE ARGS... — git の引数列（`git` の後ろ）を role 別の allowlist で判定する。
# 先頭のオプションを読み飛ばしてサブコマンドを特定し、-c は全ロール一律で deny する
# （core.fsmonitor/core.pager/core.sshCommand 注入対策）。-C/--git-dir 等は値ごと読み飛ばす。
guard::check_git() {
  local role="$1"; shift
  local sub="" i=0 tok
  local -a args=("$@") rest=()
  while [ "$i" -lt "${#args[@]}" ]; do
    tok="${args[$i]}"
    case "$tok" in
      -c)
        # -c <key>=<value> は本物 git への委譲後にそのプロセス内だけで設定を一時上書きし、
        # core.pager・core.fsmonitor・core.sshCommand のようなシェル実行を伴う設定キーへの注入を
        # 許してしまう。どのアクターも正当に必要としないため、キーを問わず一律で deny する。
        guard::deny "role=${role} は -c によるgit設定の一時上書きを実行できない"
        ;;
      -C | --git-dir | --work-tree | --namespace)
        i=$((i + 2)) ;;   # リポジトリ指定フラグは値ごと読み飛ばす。
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
          : # 読み取り専用サブコマンドの allowlist。
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
        "" | log | show | diff | status | rev-parse | blame | cat-file | ls-files | ls-tree | for-each-ref | rev-list | describe | shortlog | show-ref | name-rev | grep | var | help | version | \
        add | checkout | switch | restore | reset | revert | cherry-pick | merge | rebase | stash | mv | rm | clean | apply | branch | tag | notes)
          : # 上記に worktree 内で状態を変えるサブコマンドを加えた allowlist（push・network は除く）。
          ;;
        *)
          guard::deny "role=${role} は許可された git サブコマンド以外（${sub}）を実行できない"
          ;;
      esac
      ;;
    *)
      guard::deny "role=${role} は未知のロールのため git を実行できない"
      ;;
  esac
}

# guard::scan COMMAND — command を引用符を除いた語列 GUARD_WORDS へ分解し、無引用の複合演算子
# （& | ; ( ) ` と $( と \<改行>）を見たら GUARD_HAS_OP=1 にする。完全なシェル文法の再現ではなく、
# 「単純コマンドの語を取り出す」ことと「複合コマンドを検知する」ことだけを担う。引用符内はリテラルとして
# 一語に連結し、内部の区切りや演算子は境界にしない（`-m "wip; done"` の中の ; を演算子にしない）。
guard::scan() {
  local s="$1" n c q cur="" have=0
  local -i i=0
  n=${#s}
  GUARD_WORDS=(); GUARD_HAS_OP=0
  while [ "$i" -lt "$n" ]; do
    c="${s:$i:1}"
    case "$c" in
      "'" | '"')
        q="$c"; have=1; i=$((i + 1))
        while [ "$i" -lt "$n" ] && [ "${s:$i:1}" != "$q" ]; do
          cur="${cur}${s:$i:1}"; i=$((i + 1))
        done
        i=$((i + 1))
        ;;
      '\')
        if [ "$((i + 1))" -ge "$n" ]; then
          i=$((i + 1))
        elif [ "${s:$((i + 1)):1}" = $'\n' ]; then
          GUARD_HAS_OP=1; i=$((i + 2))   # 行継続（\<改行>）。演算子扱いで複合として弾く。
        else
          cur="${cur}${s:$((i + 1)):1}"; have=1; i=$((i + 2))
        fi
        ;;
      '&' | '|' | ';' | '(' | ')' | '`')
        GUARD_HAS_OP=1
        [ "$have" -eq 1 ] && { GUARD_WORDS+=("$cur"); cur=""; have=0; }
        i=$((i + 1))
        ;;
      ' ' | $'\t' | $'\n' | $'\r')
        [ "$have" -eq 1 ] && { GUARD_WORDS+=("$cur"); cur=""; have=0; }
        i=$((i + 1))
        ;;
      *)
        cur="${cur}${c}"; have=1; i=$((i + 1))
        ;;
    esac
  done
  [ "$have" -eq 1 ] && GUARD_WORDS+=("$cur")
  return 0   # 末尾の [ ] && ... が have=0 のとき 1 を返し set -e を誤爆させないよう明示する。
}

# guard::check_bash ROLE COMMAND — command を分解し git の役割別ポリシーを適用する。
# 先頭の VAR=val 代入と env を読み飛ばして実効コマンドを見る。それが git なら、複合コマンドは
# 安全に切り出せないため deny し、単純なら引数を check_git へ渡す。実効コマンドが git でなくても
# 語のどこかに git があれば（複合の後半・`xargs git push` 等）安全に判定できないため deny する。
guard::check_bash() {
  local role="$1" command="$2" w
  guard::scan "$command"
  local -i j=0
  while [ "$j" -lt "${#GUARD_WORDS[@]}" ]; do
    case "${GUARD_WORDS[$j]:-}" in
      *=* | env) j=$((j + 1)) ;;   # 先頭の VAR=val 代入と env は読み飛ばす。
      *) break ;;
    esac
  done
  if [ "${GUARD_WORDS[$j]:-}" = "git" ]; then
    [ "$GUARD_HAS_OP" -eq 1 ] &&
      guard::deny "role=${role} は git を含む複合コマンドを実行できない（単一の git コマンドに分けて実行する）"
    guard::check_git "$role" "${GUARD_WORDS[@]:$((j + 1))}"
    return 0
  fi
  for w in "${GUARD_WORDS[@]+"${GUARD_WORDS[@]}"}"; do
    [ "$w" = "git" ] &&
      guard::deny "role=${role} は git を安全に判定できない形（複合・埋め込み）で実行できない"
  done
  return 0
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

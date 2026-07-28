#!/usr/bin/env bash
# lib/actors.sh — Trinity のステートレスなアクター呼び出し層。
#
# bin/trinity から source して使う。各 LLM ステップを headless な `claude -p` 子プロセス
# として起動し、受け渡しはすべてファイル経由で行う。これにより Evaluator の独立性
# （自分でコードを直せない・他者のチャット文脈を見ない）がプロセス境界として強制される。
#
# アクターの振る舞いの単一の正は agents/<role>.md である。本ファイルはその本文を
# システム指示として注入し、ランタイム入力だけを差し込む。プロンプトの二重管理はしない。
#
# 環境変数: TRINITY_ROOT / RUN_DIR / WORKTREE_DIR / BRANCH
#            TRINITY_{PLANNER,GENERATOR,EVALUATOR}_MODEL

: "${TRINITY_PLANNER_MODEL:=opus}"
: "${TRINITY_GENERATOR_MODEL:=sonnet}"
: "${TRINITY_EVALUATOR_MODEL:=sonnet}"

readonly TRINITY_RC_NEEDS_INPUT=10
readonly TRINITY_RC_LOW_MEMORY=20
readonly TRINITY_RC_KILLED=21

# trinity::log MSG — RUN_DIR/trinity.log と stderr の両方へ追記する。
trinity::log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "${RUN_DIR}/trinity.log" >&2
}

# trinity::status STATE — 状態を1語で RUN_DIR/status に記録する。
# 取りうる値: planning generating reviewing evaluating needs-input needs-revision revising passed failed error
# passed/failed/error のみ終端。failed はループ上限到達を表し、FAIL 判定（継続）は revising を使う。
trinity::status() {
  printf '%s\n' "$1" > "${RUN_DIR}/status"
  trinity::log "status -> $1"
}

# trinity::agent_body ROLE — agents/<role>.md の本文（frontmatter を除く）を出力する。
trinity::agent_body() {
  local file="${TRINITY_ROOT}/agents/$1.md"
  awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{f=0;next} !f{print}' "$file"
}

# trinity::guard_settings — lib/guard.sh を PreToolUse フックとして注入する --settings JSON。
# 役割ごとの許否は TRINITY_ROLE（env）で guard.sh 自身が分岐するため、JSON 自体は共通でよい。
# matcher は Write/Edit/NotebookEdit（ファイル書き込みの範囲）と Bash（git の役割別ポリシー）を
# 対象とする。git は guard.sh が command を分解して直接判定する（PATH は一切いじらない）。
trinity::guard_settings() {
  local escaped_root="${TRINITY_ROOT//\\/\\\\}"
  escaped_root="${escaped_root//\"/\\\"}"
  printf '{"hooks":{"PreToolUse":[{"matcher":"Write|Edit|NotebookEdit|Bash","hooks":[{"type":"command","command":"%s/lib/guard.sh"}]}]}}' \
    "${escaped_root}"
}

# trinity::claude ROLE MODEL CWD PROMPT — headless な claude を1回起動し標準出力を返す。
# CLAUDECODE を外してネスト起動を避け、bypassPermissions で worktree のツールを許可しつつ、
# lib/guard.sh を PreToolUse フックとして per-actor 注入し、Write/Edit と Bash の git の役割境界を
# 単層で enforce する（PATH は一切いじらない）。
# --strict-mcp-config で利用者グローバルの MCP サーバ（playwright→Chromium・supabase・notion 等）を
# 継承しない。アクターは組み込みツール（Read/Write/Edit/Bash/Glob/Grep）と git だけで完結し、これらは
# 一切使わない。継承すると子1本あたり約 350MB の未使用サーバが常駐してメモリ圧の主因になり、かつ
# 隔離されたコード生成が利用者の Notion/DB へ触れ得る不整合も生む。空きが無いので継承を断つ。
trinity::claude() {
  local role="$1" model="$2" cwd="$3" prompt="$4"
  ( cd "$cwd" && env -u CLAUDECODE TRINITY_ROLE="$role" \
      claude -p "$prompt" \
      --model "$model" --permission-mode bypassPermissions \
      --strict-mcp-config \
      --settings "$(trinity::guard_settings)" )
}

# trinity::memory_available_pct — 利用可能メモリの割合(%)を返す。測れない環境では空を返す。
# darwin は kern.memorystatus_level（jetsam がプロセスを殺すか判断する指標そのもの。
# `memory_pressure` の "free percentage" と一致する）。macOS の「空きページ」は常時わずかで
# 誤判定するため、reclaim 可能分を織り込んだこの割合を使う。linux は MemAvailable/MemTotal。
trinity::memory_available_pct() {
  case "$(uname -s)" in
    Darwin) sysctl -n kern.memorystatus_level 2>/dev/null ;;
    Linux)  awk '/^MemAvailable:/{a=$2} /^MemTotal:/{t=$2} END{if(t>0)print int(a*100/t)}' /proc/meminfo 2>/dev/null ;;
  esac
}

# trinity::spawn ROLE MODEL CWD PROMPT OUTFILE — メモリ preflight 付きで claude を起動する。
# アクター起動の唯一の入口。2つの失敗様式を構造的に扱う:
#   1. 起動前にメモリ圧が高ければ（利用可能 < TRINITY_MIN_FREE_PCT、既定 15%）起動せず
#      TRINITY_RC_LOW_MEMORY を返す。jetsam に殺される前に fail-closed で止める。
#   2. 起動後に SIGKILL 等（終了コード >=128 = 128+シグナル番号）で異常死したら
#      TRINITY_RC_KILLED を返す。メモリ圧による kill を握りつぶさず loop を止める。
# retry はしない。メモリを空けて再実行すれば checkpoint から再開する（既存の再開機構を使う）。
# 通常終了は claude の終了コードをそのまま返し、出力の中身の判定は呼び出し側に委ねる。
trinity::spawn() {
  local role="$1" model="$2" cwd="$3" prompt="$4" out="$5" pct min rc=0
  min="${TRINITY_MIN_FREE_PCT:-15}"
  pct="$(trinity::memory_available_pct)"
  if [ -n "$pct" ] && [ "$pct" -lt "$min" ]; then
    trinity::log "preflight: 利用可能メモリ ${pct}% < ${min}%。${role} を起動しない。メモリを空けて（例: Chrome / 仮想マシン / 余分な端末を終了）再実行すると checkpoint から再開する"
    trinity::status error
    return "${TRINITY_RC_LOW_MEMORY}"
  fi
  trinity::claude "$role" "$model" "$cwd" "$prompt" > "$out" 2>&1 || rc=$?
  if [ "$rc" -ge 128 ]; then
    trinity::log "${role} が signal $((rc - 128)) で異常死した（メモリ圧による kill の可能性）。loop を止める。メモリを空けて再実行すると checkpoint から再開する"
    trinity::status error
    return "${TRINITY_RC_KILLED}"
  fi
  return "$rc"
}

# trinity::verdict_of FILE — eval-*.md から VERDICT の値（PASS/NEEDS_REVISION/FAIL）を返す。
trinity::verdict_of() {
  awk '/^VERDICT:/{print $2; exit}' "$1" 2>/dev/null
}

# trinity::has_report FILE — 完了レポート（空でない）の有無を判定する。
# タスク完了の信号として複数箇所（assert_progress・チェックポイント再開判定）で共有する。
trinity::has_report() {
  [ -s "$1" ]
}

# trinity::assert_progress PRE_SHA REPORT CONTEXT — コミットか非空の完了レポートがあれば継続する。
# どちらも無ければ実装役の真の失敗として error で終了する。
trinity::assert_progress() {
  local pre_sha="$1" report="$2" context="$3" post_sha
  post_sha="$(git -C "${WORKTREE_DIR}" rev-parse HEAD 2>/dev/null || true)"
  if [ "${pre_sha}" != "${post_sha}" ]; then
    return 0
  fi
  if trinity::has_report "${report}"; then
    trinity::log "${context}: 変更不要（no-op）。理由は ${report} を参照"
    return 0
  fi
  trinity::log "${context}: Generator がコミットも完了レポートも作成しなかった"
  trinity::status error
  return 1
}

# trinity::base — リモートデフォルトブランチとの merge-base（diff・レビュー範囲の起点）。
trinity::base() {
  local remote_head
  remote_head="$(git -C "${WORKTREE_DIR}" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" || true
  remote_head="${remote_head##*/}"
  [ -z "${remote_head}" ] && remote_head="main"
  git -C "${WORKTREE_DIR}" merge-base HEAD "origin/${remote_head}" 2>/dev/null \
    || git -C "${WORKTREE_DIR}" rev-list --max-parents=0 HEAD | tail -1
}

# trinity::context LOOP — 全アクター共通のランタイム入力ブロック。
trinity::context() {
  cat <<EOF

## このランの入力
- RUN_DIR: ${RUN_DIR}
- WORKTREE_DIR: ${WORKTREE_DIR}
- BRANCH: ${BRANCH}
- 現在のループ番号: $1
- 要件: ${RUN_DIR}/requirement.md を読むこと
EOF
}

# trinity::plan LOOP — Planner を起動し plan.md と tasks.tsv を生成させる。
# plan-<n>.md と tasks.tsv が既にあれば Planner をスキップして plan.md を復元する（再開）。
# `## 要確認の論点` があれば needs-input にして 10 を返す（loop 側でブロック）。
trinity::plan() {
  local loop="$1"
  # plan-<n>.md と tasks.tsv が両方あれば Planner をスキップし plan.md を復元する（再開）。
  if [ -f "${RUN_DIR}/plan-${loop}.md" ] && [ -f "${RUN_DIR}/tasks.tsv" ]; then
    trinity::log "plan-${loop}.md が既にある。Planner をスキップし plan.md を復元する"
    cp "${RUN_DIR}/plan-${loop}.md" "${RUN_DIR}/plan.md"
    return 0
  fi
  trinity::status planning
  # tasks.tsv を事前に削除して失敗時の古いファイル誤検出を防ぐ。
  rm -f "${RUN_DIR}/tasks.tsv"
  local prompt rc=0
  prompt="$(trinity::agent_body planner)$(trinity::context "$loop")"
  trinity::spawn planner "${TRINITY_PLANNER_MODEL}" "${WORKTREE_DIR}" "$prompt" \
    "${RUN_DIR}/planner-${loop}.out" || rc=$?
  [ "$rc" -ge "${TRINITY_RC_LOW_MEMORY}" ] && return "$rc"
  if [ ! -f "${RUN_DIR}/plan.md" ]; then
    trinity::status error; return 1
  fi
  # ## 要確認の論点 があるときは tasks.tsv を書かない（仕様）ため、この順で判定する。
  if grep -q '^## 要確認の論点' "${RUN_DIR}/plan.md"; then
    trinity::status needs-input
    return "${TRINITY_RC_NEEDS_INPUT}"
  fi
  if [ ! -f "${RUN_DIR}/tasks.tsv" ]; then
    trinity::status error; return 1
  fi
  # 計画成功後に plan.md を plan-<n>.md へスナップショットする（再開のチェックポイント）。
  cp "${RUN_DIR}/plan.md" "${RUN_DIR}/plan-${loop}.md"
  return 0
}

# trinity::generate LOOP — tasks.tsv の各行ごとに Generator を新規起動する（正当な変更不要ならコミット無しで完了する）。
# gen-<n>-task-<i>.md（完了レポート）が既にあるタスクはスキップする（再開のチェックポイント）。
trinity::generate() {
  local loop="$1" idx title files prompt pre_sha agent_body rc
  trinity::status generating
  local total; total="$(awk -F'\t' '$1~/^[0-9]+$/{n++} END{print n+0}' "${RUN_DIR}/tasks.tsv" 2>/dev/null || echo 0)"
  agent_body="$(trinity::agent_body generator)"
  while IFS=$'\t' read -r idx title files; do
    case "${idx}" in ''|*[!0-9]*) continue ;; esac   # 空行・ヘッダ行を飛ばす
    if trinity::has_report "${RUN_DIR}/gen-${loop}-task-${idx}.md"; then
      trinity::log "generate loop ${loop} task ${idx}/${total}: スキップ（完了済み）"
      continue
    fi
    trinity::log "generate loop ${loop} task ${idx}/${total}: ${title}"
    pre_sha="$(git -C "${WORKTREE_DIR}" rev-parse HEAD 2>/dev/null || true)"
    prompt="${agent_body}$(trinity::context "$loop")
- TaskIndex: ${idx}
- TaskTotal: ${total}
- TaskTitle: ${title}
- TaskFiles: ${files}"
    rc=0
    trinity::spawn generator "${TRINITY_GENERATOR_MODEL}" "${WORKTREE_DIR}" "$prompt" \
      "${RUN_DIR}/gen-${loop}-task-${idx}.out" || rc=$?
    [ "$rc" -ge "${TRINITY_RC_LOW_MEMORY}" ] && return "$rc"
    trinity::assert_progress "${pre_sha}" "${RUN_DIR}/gen-${loop}-task-${idx}.md" "generate task ${idx}"
  done < "${RUN_DIR}/tasks.tsv"
}

# trinity::revise LOOP — FAIL のとき計画の範囲内で修正コミットを作らせる。
# gen-<n>-revise.md（完了レポート）が既にあればスキップする（再開のチェックポイント）。
trinity::revise() {
  local loop="$1" prompt pre_sha rc=0
  if trinity::has_report "${RUN_DIR}/gen-${loop}-revise.md"; then
    trinity::log "gen-${loop}-revise.md が既にある。revise をスキップする"
    return 0
  fi
  trinity::status generating
  pre_sha="$(git -C "${WORKTREE_DIR}" rev-parse HEAD 2>/dev/null || true)"
  prompt="$(trinity::agent_body generator)$(trinity::context "$loop")
- 修正モード: ${RUN_DIR}/eval-$((loop - 1)).md の指摘を既存計画の範囲内で修正する。新規タスクは追加しない。"
  trinity::spawn generator "${TRINITY_GENERATOR_MODEL}" "${WORKTREE_DIR}" "$prompt" \
    "${RUN_DIR}/gen-${loop}-revise.out" || rc=$?
  [ "$rc" -ge "${TRINITY_RC_LOW_MEMORY}" ] && return "$rc"
  trinity::assert_progress "${pre_sha}" "${RUN_DIR}/gen-${loop}-revise.md" "revise"
}

# trinity::run_tool PROMPT OUTFILE LABEL — 前段の道具（/code-review 等）を1つ回す。
# kill・低メモリ（>=TRINITY_RC_LOW_MEMORY）はそのコードを返して loop を止める。通常エラーは
# WARN でログに残すだけで続行する（証拠が1つ欠けても Evaluator は残りの証拠で判定できる）。
trinity::run_tool() {
  local prompt="$1" out="$2" label="$3" rc=0
  trinity::spawn generator "${TRINITY_GENERATOR_MODEL}" "${WORKTREE_DIR}" "$prompt" "$out" || rc=$?
  [ "$rc" -ge "${TRINITY_RC_LOW_MEMORY}" ] && return "$rc"
  [ "$rc" -ne 0 ] && trinity::log "WARN: ${label} が exit ${rc} で終了した"
  return 0
}

# trinity::tools LOOP — /code-review --fix・/simplify・/verify を前段で回す（Evaluator の証拠収集）。
trinity::tools() {
  local loop="$1" base; base="$(trinity::base)"
  trinity::status reviewing
  trinity::run_tool "/code-review --fix ${base}..HEAD" "${RUN_DIR}/review-${loop}.md" "/code-review --fix" || return $?
  trinity::run_tool "/simplify" "${RUN_DIR}/simplify-${loop}.md" "/simplify" || return $?
  # 道具が適用した修正があればコミットして、Evaluator が見る差分を確定させる。
  # これはハーネス自身が発行する git であり claude -p 子の PreToolUse フックの対象外。
  if [ -n "$(git -C "${WORKTREE_DIR}" status --porcelain)" ]; then
    git -C "${WORKTREE_DIR}" add -A || true
    git -C "${WORKTREE_DIR}" commit -q -m "chore: 道具の自動修正を反映する" || true
  fi
  trinity::run_tool "/verify この差分が要件どおり動くかをアプリで確認し、結果を簡潔に報告する。" \
    "${RUN_DIR}/verify-${loop}.md" "/verify" || return $?
}

# trinity::evaluate LOOP — Evaluator を起動し eval-<n>.md を書かせる。戻り値: 0=PASS 2=NEEDS_REVISION 3=FAIL 1=不明。
trinity::evaluate() {
  local loop="$1" prompt verdict rc=0
  trinity::status evaluating
  prompt="$(trinity::agent_body evaluator)$(trinity::context "$loop")
- ループ内最終コミット: $(git -C "${WORKTREE_DIR}" rev-parse HEAD)
- 道具の出力: review-${loop}.md / simplify-${loop}.md / verify-${loop}.md"
  trinity::spawn evaluator "${TRINITY_EVALUATOR_MODEL}" "${WORKTREE_DIR}" "$prompt" \
    "${RUN_DIR}/evaluator-${loop}.out" || rc=$?
  [ "$rc" -ge "${TRINITY_RC_LOW_MEMORY}" ] && return "$rc"
  verdict="$(trinity::verdict_of "${RUN_DIR}/eval-${loop}.md")"
  case "${verdict}" in
    PASS)           trinity::status passed;        return 0 ;;
    NEEDS_REVISION) trinity::status needs-revision; return 2 ;;
    FAIL)           trinity::status revising;       return 3 ;;
    *)              trinity::status error;          return 1 ;;
  esac
}

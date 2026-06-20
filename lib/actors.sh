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
#            TRINITY_{PLANNER,GENERATOR,EVALUATOR}_MODEL / TRINITY_DRY_RUN

: "${TRINITY_PLANNER_MODEL:=opus}"
: "${TRINITY_GENERATOR_MODEL:=sonnet}"
: "${TRINITY_EVALUATOR_MODEL:=sonnet}"
: "${TRINITY_DRY_RUN:=0}"

# trinity::log MSG — RUN_DIR/trinity.log と stderr の両方へ追記する。
trinity::log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "${RUN_DIR}/trinity.log" >&2
}

# trinity::status STATE — 状態を1語で RUN_DIR/status に記録する。
# 取りうる値: planning generating reviewing evaluating needs-input passed needs-revision failed error
trinity::status() {
  printf '%s\n' "$1" > "${RUN_DIR}/status"
  trinity::log "status -> $1"
}

# trinity::agent_body ROLE — agents/<role>.md の本文（frontmatter を除く）を出力する。
trinity::agent_body() {
  local file="${TRINITY_ROOT}/agents/$1.md"
  awk 'NR==1 && $0=="---"{f=1;next} f && $0=="---"{f=0;next} !f{print}' "$file"
}

# trinity::claude MODEL CWD PROMPT — headless な claude を1回起動し標準出力を返す。
# CLAUDECODE を外してネスト起動を避け、bypassPermissions で worktree のツールを許可する。
trinity::claude() {
  local model="$1" cwd="$2" prompt="$3"
  if [ "${TRINITY_DRY_RUN}" = "1" ]; then
    printf '%s\n' "[dry-run ${model}] $(printf '%.70s' "$prompt")" >&2
    return 0
  fi
  ( cd "$cwd" && env -u CLAUDECODE claude -p "$prompt" \
      --model "$model" --permission-mode bypassPermissions )
}

# trinity::base — origin/main との merge-base（diff・レビュー範囲の起点）。
trinity::base() {
  git -C "${WORKTREE_DIR}" merge-base HEAD origin/main 2>/dev/null \
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
# `## 要確認の論点` があれば needs-input にして 10 を返す（loop 側でブロック）。
trinity::plan() {
  local loop="$1"
  trinity::status planning
  if [ "${TRINITY_DRY_RUN}" = "1" ]; then
    printf '# plan (dry-run loop %s)\n\n## 受け入れ基準\n- 動作する\n' "$loop" > "${RUN_DIR}/plan.md"
    printf '1\tdry-run タスク\t-\n' > "${RUN_DIR}/tasks.tsv"
    return 0
  fi
  local prompt
  prompt="$(trinity::agent_body planner)$(trinity::context "$loop")"
  trinity::claude "${TRINITY_PLANNER_MODEL}" "${WORKTREE_DIR}" "$prompt" \
    > "${RUN_DIR}/planner-${loop}.out" 2>&1 || true
  if [ ! -f "${RUN_DIR}/plan.md" ]; then
    trinity::status error; return 1
  fi
  if grep -q '^## 要確認の論点' "${RUN_DIR}/plan.md"; then
    trinity::status needs-input
    return 10
  fi
  return 0
}

# trinity::generate LOOP — tasks.tsv の各行ごとに Generator を新規起動する（1タスク=1コミット）。
trinity::generate() {
  local loop="$1" idx title files prompt
  trinity::status generating
  if [ "${TRINITY_DRY_RUN}" = "1" ]; then
    git -C "${WORKTREE_DIR}" commit --allow-empty -q -m "feat: dry-run loop ${loop}" || true
    printf 'commit %s\n' "$(git -C "${WORKTREE_DIR}" rev-parse HEAD)" \
      > "${RUN_DIR}/gen-${loop}-task-1.md"
    return 0
  fi
  local total; total="$(grep -c $'\t' "${RUN_DIR}/tasks.tsv" 2>/dev/null || echo 0)"
  while IFS=$'\t' read -r idx title files; do
    [ -z "${idx}" ] && continue
    trinity::log "generate loop ${loop} task ${idx}/${total}: ${title}"
    prompt="$(trinity::agent_body generator)$(trinity::context "$loop")
- TaskIndex: ${idx}
- TaskTotal: ${total}
- TaskTitle: ${title}
- TaskFiles: ${files}"
    trinity::claude "${TRINITY_GENERATOR_MODEL}" "${WORKTREE_DIR}" "$prompt" \
      > "${RUN_DIR}/gen-${loop}-task-${idx}.out" 2>&1 || true
  done < "${RUN_DIR}/tasks.tsv"
}

# trinity::revise LOOP — FAIL のとき計画の範囲内で修正コミットを作らせる。
trinity::revise() {
  local loop="$1" prev prompt
  prev=$((loop - 1))
  trinity::status generating
  if [ "${TRINITY_DRY_RUN}" = "1" ]; then
    git -C "${WORKTREE_DIR}" commit --allow-empty -q -m "fix: dry-run revise loop ${loop}" || true
    printf 'commit %s\n' "$(git -C "${WORKTREE_DIR}" rev-parse HEAD)" \
      > "${RUN_DIR}/gen-${loop}-task-1.md"
    return 0
  fi
  prompt="$(trinity::agent_body generator)$(trinity::context "$loop")
- 修正モード: ${RUN_DIR}/eval-${prev}.md の指摘を既存計画の範囲内で修正し、コミットする。新規タスクは追加しない。"
  trinity::claude "${TRINITY_GENERATOR_MODEL}" "${WORKTREE_DIR}" "$prompt" \
    > "${RUN_DIR}/gen-${loop}-revise.out" 2>&1 || true
}

# trinity::tools LOOP — /code-review --fix・/simplify・/verify を前段で回す（Evaluator の証拠収集）。
trinity::tools() {
  local loop="$1" base; base="$(trinity::base)"
  trinity::status reviewing
  if [ "${TRINITY_DRY_RUN}" = "1" ]; then
    printf 'No issues found. (dry-run)\n' > "${RUN_DIR}/review-${loop}.md"
    return 0
  fi
  trinity::claude "${TRINITY_GENERATOR_MODEL}" "${WORKTREE_DIR}" \
    "/code-review --fix ${base}..HEAD" > "${RUN_DIR}/review-${loop}.md" 2>&1 || true
  trinity::claude "${TRINITY_GENERATOR_MODEL}" "${WORKTREE_DIR}" \
    "/simplify" > "${RUN_DIR}/simplify-${loop}.md" 2>&1 || true
  # 道具が適用した修正があればコミットして、Evaluator が見る差分を確定させる。
  if [ -n "$(git -C "${WORKTREE_DIR}" status --porcelain)" ]; then
    git -C "${WORKTREE_DIR}" add -A
    git -C "${WORKTREE_DIR}" commit -q -m "chore: /code-review --fix と /simplify の修正を反映する" || true
  fi
  trinity::claude "${TRINITY_GENERATOR_MODEL}" "${WORKTREE_DIR}" \
    "/verify この差分が要件どおり動くかをアプリで確認し、結果を簡潔に報告する。" \
    > "${RUN_DIR}/verify-${loop}.md" 2>&1 || true
}

# trinity::evaluate LOOP — Evaluator を起動し eval-<n>.md を書かせる。戻り値: 0=PASS 2=NEEDS_REVISION 3=FAIL 1=不明。
trinity::evaluate() {
  local loop="$1" prompt verdict
  trinity::status evaluating
  if [ "${TRINITY_DRY_RUN}" = "1" ]; then
    printf 'VERDICT: PASS\n\n# 評価 (dry-run)\n' > "${RUN_DIR}/eval-${loop}.md"
    trinity::status passed; return 0
  fi
  prompt="$(trinity::agent_body evaluator)$(trinity::context "$loop")
- ループ内最終コミット: $(git -C "${WORKTREE_DIR}" rev-parse HEAD)
- 道具の出力: review-${loop}.md / simplify-${loop}.md / verify-${loop}.md"
  trinity::claude "${TRINITY_EVALUATOR_MODEL}" "${WORKTREE_DIR}" "$prompt" \
    > "${RUN_DIR}/evaluator-${loop}.out" 2>&1 || true
  verdict="$(grep -m1 '^VERDICT:' "${RUN_DIR}/eval-${loop}.md" 2>/dev/null | awk '{print $2}')"
  case "${verdict}" in
    PASS)           trinity::status passed;        return 0 ;;
    NEEDS_REVISION) trinity::status needs-revision; return 2 ;;
    FAIL)           trinity::status failed;         return 3 ;;
    *)              trinity::status error;          return 1 ;;
  esac
}

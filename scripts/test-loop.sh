#!/usr/bin/env bash
# scripts/test-loop.sh — loop.sh を偽の claude で通しで動かし、成果物・状態・再開を確かめる。
# `bash scripts/test-loop.sh` で走る。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 偽の claude。役割と指示の内容に応じて、本物と同じ場所に成果物を作る。
mkdir -p "$TMP/bin"
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
prompt=""
while [ $# -gt 0 ]; do
  [ "$1" = -p ] && { prompt="$2"; shift; }
  shift
done
case "${TRINITY_ROLE}:${prompt}" in
  planner:*)
    printf '# 計画\n' > "${RUN_DIR}/plan.md"
    printf '1\tタスク\t-\n' > "${RUN_DIR}/tasks.tsv" ;;
  generator:/code-review* | generator:/simplify*)
    echo "指摘なし" ;;
  generator:*)
    echo x >> "${WORKTREE_DIR}/file.txt"
    git -C "${WORKTREE_DIR}" add -A
    git -C "${WORKTREE_DIR}" commit -qm "task"
    printf '完了\n' > "${RUN_DIR}/gen-1-task-1.md" ;;
  evaluator:*)
    printf 'VERDICT: PASS\n' ;;
esac
STUB
chmod +x "$TMP/bin/claude"

git -C "$TMP" init -qb main wt
git -C "$TMP/wt" commit -q --allow-empty -m "init"

pass=0 fail=0
check() {
  if eval "$2"; then pass=$((pass + 1)); printf 'ok   %s\n' "$1"
  else fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; fi
}

# 1周目で PASS に到達し、成果物と終了状態が揃う。
PATH="$TMP/bin:$PATH" "$ROOT/scripts/loop.sh" "$TMP/run" "$TMP/wt" main 2> "$TMP/log1"
check "status が passed になる"        '[ "$(cat "$TMP/run/status")" = passed ]'
check "eval-1.md が PASS で残る"       'grep -q "VERDICT: PASS" "$TMP/run/eval-1.md"'
check "ツールの出力が残る"               '[ -s "$TMP/run/review.md" ] && [ -s "$TMP/run/simplify.md" ]'
check "タスクのコミットが作られる"     '[ "$(git -C "$TMP/wt" log -1 --format=%s)" = task ]'
check "終了時に pid が消える"          '[ ! -f "$TMP/run/pid" ]'

# PASS 済みの再実行は何もしない。
PATH="$TMP/bin:$PATH" "$ROOT/scripts/loop.sh" "$TMP/run" "$TMP/wt" main 2> "$TMP/log2"
check "再実行は PASS のまま何もしない" 'grep -q "再実行しない" "$TMP/log2" && [ ! -f "$TMP/run/eval-2.md" ]'

# 修正要望（redrive）があると PASS 済みでも作り直し、完了時に合図が消える。
touch "$TMP/run/redrive"
PATH="$TMP/bin:$PATH" "$ROOT/scripts/loop.sh" "$TMP/run" "$TMP/wt" main 2> "$TMP/log3"
check "redrive でループ 2 を回す"      'grep -q "VERDICT: PASS" "$TMP/run/eval-2.md"'
check "完了で redrive が消える"        '[ ! -f "$TMP/run/redrive" ] && [ "$(cat "$TMP/run/status")" = passed ]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

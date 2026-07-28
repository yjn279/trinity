#!/usr/bin/env bash
# tests/actor-mcp-isolation.sh — trinity::claude が利用者グローバルの MCP サーバを継承しないこと
# （--strict-mcp-config を渡すこと）を検証する。継承すると子1本あたり約 350MB の未使用サーバが
# 常駐してメモリ圧の主因になるため、この不変条件を機構で守る。
#
# 本物の claude を、引数を記録するだけのスタブに差し替え、trinity::claude の実際の起動引数を検査する。
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TRINITY_ROOT="$ROOT"; export TRINITY_ROOT
# shellcheck source=lib/actors.sh
. "${ROOT}/lib/actors.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ARGS_OUT="${TMP}/args"; export ARGS_OUT
# スタブ claude: 受け取った引数を1行ずつ記録して終了する。
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$ARGS_OUT"\n' > "${TMP}/claude"
chmod +x "${TMP}/claude"

PATH="${TMP}:${PATH}" trinity::claude planner opus "${TMP}" "prompt" >/dev/null 2>&1

pass=0; fail=0
grep -qx -- '--strict-mcp-config' "$ARGS_OUT" \
  && { pass=$((pass+1)); echo "ok   trinity::claude は --strict-mcp-config を渡す（MCP 非継承）"; } \
  || { fail=$((fail+1)); echo "FAIL --strict-mcp-config が起動引数に無い"; }
# --mcp-config は渡さない（strict のみで全 MCP を無効化する。空設定ファイルも要らない）。
grep -qx -- '--mcp-config' "$ARGS_OUT" \
  && { fail=$((fail+1)); echo "FAIL 不要な --mcp-config を渡している"; } \
  || { pass=$((pass+1)); echo "ok   余計な --mcp-config は渡さない"; }

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

# Shared helpers for gateway/setup.sh and gateway/teardown.sh. Source this; do not run it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$HERE/.state.env"
PREFIX="${PREFIX:-aigwjwt-e2e}"  # workspace names must stay short: the API rejects a scope name over 32 characters
DRY_RUN=0; for a in "$@"; do [[ "$a" == --dry-run ]] && DRY_RUN=1; done

log() { printf '[%s] %s\n' "$(basename "$0")" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
command -v airs-cli >/dev/null || die "airs-cli not found"
command -v python3 >/dev/null || die "python3 not found"
run() { if (( DRY_RUN )); then log "DRY-RUN: $*"; else "$@"; fi; }

# airs-cli prints JSON, sometimes with decoration around it. jx '<python expr over d>' parses stdin.
jx() {
  python3 -c '
import sys, json
t = sys.stdin.read()
i = min([x for x in (t.find("["), t.find("{")) if x >= 0] or [0])
try: d = json.JSONDecoder().raw_decode(t[i:])[0]
except Exception: d = None
if isinstance(d, dict):
    for v in d.values():
        if isinstance(v, list): d = v; break
print(eval(sys.argv[1]))' "$1"
}
# obj '<python expr over d>' parses a single JSON object from stdin (no list flattening, unlike jx)
obj() {
  python3 -c '
import sys, json
t = sys.stdin.read()
try: d = json.JSONDecoder().raw_decode(t[t.find("{"):])[0]
except Exception: d = {}
print(eval(sys.argv[1]))' "$1"
}
# first list item whose field equals value, as JSON (empty if none)
find_by() { jx "next((json.dumps(x) for x in (d or []) if isinstance(x, dict) and str(x.get('$1')) == '$2'), '')"; }
field() { python3 -c '
import sys, json
t = sys.stdin.read().strip()
v = (json.loads(t) if t else {}).get(sys.argv[1], "")
print("" if v is None else v)' "$1"; }

state_set() { (( DRY_RUN )) && return 0; touch "$STATE"; chmod 600 "$STATE"; { grep -v "^$1=" "$STATE" || true; printf '%s=%s\n' "$1" "$2"; } > "$STATE.new"; chmod 600 "$STATE.new"; mv "$STATE.new" "$STATE"; }
state_get() { [[ -f "$STATE" ]] && { grep "^$1=" "$STATE" | tail -1 | cut -d= -f2- || true; } || true; }

TMP=""; RESTORE_TENANT=""
on_exit() {
  [[ -z "$TMP" ]] || rm -rf "$TMP"
  [[ -z "$RESTORE_TENANT" ]] || airs-cli tenant switch "$RESTORE_TENANT" >/dev/null 2>&1 || true
}
trap on_exit EXIT

# Select the airs-cli tenant (AIRS_TENANT, default: the active one) and restore the previous one on exit.
use_tenant() {
  local prev; prev=$(airs-cli tenant list --output json 2>/dev/null | jx "next((x['name'] for x in d if x.get('selected') or x.get('active')), '')") || true
  AIRS_TENANT="${AIRS_TENANT:-$prev}"
  [[ -n "$AIRS_TENANT" ]] || die "set AIRS_TENANT (no active airs-cli tenant)"
  if [[ "$AIRS_TENANT" != "$prev" ]]; then
    RESTORE_TENANT="$prev"
    airs-cli tenant switch "$AIRS_TENANT" >/dev/null 2>&1 || die "tenant '$AIRS_TENANT' is not registered in airs-cli"
  fi
  TSG_ID=$(airs-cli tenant list --output json 2>/dev/null | jx "next((str(x.get('tsgId','')) for x in d if x['name'] == '$AIRS_TENANT'), '')")
  [[ "$TSG_ID" =~ ^[0-9]+$ ]] || die "TSG id of tenant $AIRS_TENANT not found"
  log "tenant: $AIRS_TENANT (TSG $TSG_ID)"
}

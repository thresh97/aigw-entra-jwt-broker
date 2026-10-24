#!/usr/bin/env bash
# run.sh: re-run this article's tests. See the README's "Re-run" section.
#   run.sh list                 scenarios, what each changes, how long it takes
#   run.sh check                read-only preflight: tools, env, credentials, versions
#   run.sh <scenario> [--yes]   one scenario; --yes is required for scenarios that change shared state
#   run.sh all [--yes]          every scenario
# Results: repro/results/<date>-<scenario>/{run.log,summary.txt}. Verdict: PASS, CHANGED or ERROR.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
[[ -f $HERE/env ]] || { echo "ERROR: copy env.example to env and fill it in"; exit 2; }
# shellcheck source=/dev/null
source "$HERE/env"

# ---------------------------------------------------------------- framework (keep as is)
OUT= OBS=0 DIFF=0
CLEANUP=()
log()     { echo "$(date -u +%H:%M:%SZ) $*" | tee -a "$OUT/run.log"; }
mask()    { sed -E 's/[A-Za-z0-9+\/_=-]{24,}/<masked>/g'; }          # pipe anything that might carry a secret
fp()      { echo "len $(wc -c < "$1") tail $(tail -c3 "$1") sha $(sha256sum < "$1" | cut -c1-12)"; }  # a secret file, safely
need()    { for v; do [[ -n ${!v:-} ]] || { echo "ERROR: $v is empty in env"; exit 2; }; done; }
on_exit() { CLEANUP+=("$*"); }                                    # registered undo steps run in reverse, even on failure
expect()  { # expect "<what>" "<expected>" "<observed>"
  OBS=$((OBS+1)); if [[ $2 == "$3" ]]; then r=ok; else r=DIFF; DIFF=$((DIFF+1)); fi
  printf '%-4s %s: expected %s, observed %s\n' "$r" "$1" "$2" "$3" | tee -a "$OUT/summary.txt" | tee -a "$OUT/run.log"; }
cleanup() { local i; for ((i=${#CLEANUP[@]}-1; i>=0; i--)); do log "cleanup: ${CLEANUP[i]}"; eval "${CLEANUP[i]}" 2>&1 | mask | tee -a "$OUT/run.log"; done; CLEANUP=(); }
start()   { # start <scenario>
  local d=$HERE/results/$(date -u +%F) s=; for s in "" -b -c -d -e -f -g -h; do [[ -e $d$s-$1 ]] || break; done
  OUT=$d$s-$1; mkdir -p "$OUT"; chmod 700 "$OUT"; : > "$OUT/summary.txt"; OBS=0 DIFF=0
  { echo "scenario: $1"; echo "date: $(date -u +%FT%TZ)"; versions; } >> "$OUT/summary.txt"; trap 'cleanup; finish ERROR' EXIT; }
finish()  { trap - EXIT; cleanup
  local v=${1:-}; [[ -n $v ]] || { ((OBS == 0)) && v=ERROR || { ((DIFF)) && v=CHANGED || v=PASS; }; }
  echo "verdict: $v ($OBS observations, $DIFF differ)" | tee -a "$OUT/summary.txt"; echo "results: $OUT"; }
guard()   { [[ " ${ARGS[*]:-} " == *" --yes "* ]] || { echo "ERROR: $1 changes shared state ($2); re-run with --yes"; exit 2; }; }

# ---------------------------------------------------------------- article-specific
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=/dev/null
[[ -f $ROOT/entra/.state.env ]] && source "$ROOT/entra/.state.env"
JWT="node $HERE/jwt.cjs"

versions() {
  echo "node: $(node --version 2>/dev/null || echo unknown)"
  echo "az: $(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo unknown)"
  echo "gateway: ${GATEWAY_VERSION:-unknown}"; }

check() {
  need BROKER_URL ENTRA_TENANT_ID ENTRA_APP_ID_URI CLIENT_FINANCE_ID CLIENT_FINANCE_SECRET CLIENT_HR_ID CLIENT_HR_SECRET CLIENT_NOROLE_ID CLIENT_NOROLE_SECRET \
       FINANCE_WORKSPACE FINANCE_CONFIG_SLUG HR_WORKSPACE HR_CONFIG_SLUG
  for t in curl jq node; do command -v "$t" >/dev/null || { echo "ERROR: $t not installed"; exit 2; }; done
  [[ -d $ROOT/broker/node_modules/jose ]] || { echo "ERROR: run 'npm ci' in broker/ (jwt.cjs uses its jose)"; exit 2; }
  curl -fsS "$BROKER_URL/.well-known/jwks.json" | jq -e '.keys|length>0' >/dev/null || { echo "ERROR: no JWKS at $BROKER_URL"; exit 2; }
  [[ -n ${GATEWAY_URL:-} ]] || echo "note: GATEWAY_URL empty, gateway scenarios will be skipped"
  command -v az >/dev/null || echo "note: az not installed, the rotation scenario will not run"
  versions; echo "check: ok"; }

# entra_token <id> <secret>  -> access token on stdout, or nothing; the HTTP body is kept in $OUT/last-entra.json (token masked)
entra_token() {
  local body
  body=$(printf 'grant_type=client_credentials&client_id=%s&client_secret=%s&scope=%s' "$1" "$2" "$(jq -rn --arg s "$ENTRA_APP_ID_URI/.default" '$s|@uri')" |
    curl -sS -X POST "https://login.microsoftonline.com/$ENTRA_TENANT_ID/oauth2/v2.0/token" -H 'Content-Type: application/x-www-form-urlencoded' --data @-)
  echo "$body" | jq 'if .access_token then .access_token="<masked>" else . end' > "$OUT/last-entra.json"
  echo "$body" | jq -r '.access_token // empty'; }

# exchange <entra token>  -> prints "<status> <body>" ; body is the broker JSON
exchange() { curl -sS -o "$OUT/ex.body" -w '%{http_code}' -X POST "$BROKER_URL/token/exchange" ${1:+-H "Authorization: Bearer $1"}; }
minted() { jq -r '.token // .access_token // empty' "$OUT/ex.body"; }

# user_token <upn> <password>  -> delegated access token (ROPC) on stdout, or nothing; HTTP body kept in $OUT/last-entra.json (token masked)
user_token() {
  local body
  body=$(printf 'grant_type=password&client_id=%s&username=%s&password=%s&scope=%s' "$PUBLIC_CLIENT_ID" "$(jq -rn --arg s "$1" '$s|@uri')" "$(jq -rn --arg s "$2" '$s|@uri')" "$(jq -rn --arg s "$ENTRA_APP_ID_URI/access_as_user" '$s|@uri')" |
    curl -sS -X POST "https://login.microsoftonline.com/$ENTRA_TENANT_ID/oauth2/v2.0/token" -H 'Content-Type: application/x-www-form-urlencoded' --data @-)
  echo "$body" | jq 'if .access_token then .access_token="<masked>" else . end' > "$OUT/last-entra.json"
  echo "$body" | jq -r '.access_token // empty'; }

# gw <jwt> [extra curl args]  -> HTTP status; body in $OUT/gw.body, headers in $OUT/gw.hdr
# Anthropic Messages API. The token's config (a fallback over the mock upstream) decides which target answers.
gw() { local t=$1; shift
  curl -sS -D "$OUT/gw.hdr" -o "$OUT/gw.body" -w '%{http_code}' "$GATEWAY_URL/v1/messages" \
    -H "Authorization: Bearer $t" -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' "$@" \
    -d "{\"model\":\"${GATEWAY_MODEL:-claude-3-haiku}\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"; }
# Which fallback target answered the last gw call (0 = the workspace default config, 1 = config b, 2 = config c).
# The header value looks like config.targets[1].
opt_index() { grep -i '^x-portkey-last-used-option-index' "$OUT/gw.hdr" | tr -d '\r' | sed -E 's/.*\[([0-9]+)\].*/\1/'; }
need_gw() { [[ -n ${GATEWAY_URL:-} ]] || { echo "SKIP: GATEWAY_URL empty"; exit 2; }; }

SCENARIOS=(broker modea-ok modea-user negative mode-b rotation)
describe_broker()          { echo "broker: Entra client-credentials -> exchange -> verify minted token against live JWKS; no-role, no-token, garbage callers refused. Changes: nothing. About 1 min."; }
describe_modea-ok()        { echo "modea-ok: minted finance and hr tokens as Bearer on the gateway; the answering config (option index 1 and 2) shows the token's config_slug was applied. Changes: nothing (needs the broker's JWKS in the org settings). About 1 min."; }
describe_modea-user()      { echo "modea-user: the user path (ROPC): alice, bob, carol. The gateway checks user tokens for workspace membership: with JWT_JIT_USER_ACCESS off on the gateway expect 403 code 033 (JIT_USER_ACCESS=off, the default here); with it ON (JIT_USER_ACCESS=on) a non-member user is admitted as a workspace service key, so expect 200 and index 1 (alice, carol) or 2 (bob). Changes: nothing. About 1 min."; }
describe_negative()       { echo "negative: tampered payload, signature, kid and no token at the gateway: status and message. Changes: nothing. About 1 min."; }
describe_mode-b()          { echo "mode-b: an unmodified Entra token sent straight to the gateway (baseline for why the broker exists). Changes: nothing. About 1 min."; }
describe_rotation()        { echo "rotation: new Key Vault key version, both in JWKS, old token still valid, JWKS cache lag measured. Changes: adds a key version (the new one is disabled again at the end). About 10 min."; }

scenario_broker() {
  start broker
  local t st
  jq -e '.keys|all(.kty=="RSA" and (has("d")|not) and .kid and .alg=="RS256" or .alg==null)' <(curl -fsS "$BROKER_URL/.well-known/jwks.json") >/dev/null; expect "JWKS holds public RSA keys with kid and no private part" 0 $?
  curl -fsS "$BROKER_URL/.well-known/jwks.json" | jq -c '{kids:[.keys[].kid]}' >> "$OUT/run.log"

  t=$(entra_token "$CLIENT_FINANCE_ID" "$CLIENT_FINANCE_SECRET"); expect "finance client got an Entra token" yes "$([[ -n $t ]] && echo yes || echo no)"
  echo "$t" | $JWT claims | jq -c '{ver,iss,aud,roles,idtyp,email}' | tee -a "$OUT/run.log"
  st=$(exchange "$t"); expect "finance exchange status" 200 "$st"
  m=$(minted); $JWT verify "$BROKER_URL/.well-known/jwks.json" <<<"$m" >"$OUT/finance.claims" 2>>"$OUT/run.log"; expect "minted token verifies against live JWKS" 0 $?
  jq -c . "$OUT/finance.claims" | tee -a "$OUT/run.log"
  expect "portkey_workspace" "$FINANCE_WORKSPACE" "$(jq -r .portkey_workspace "$OUT/finance.claims")"
  expect "defaults.config_slug" "$FINANCE_CONFIG_SLUG" "$(jq -r .defaults.config_slug "$OUT/finance.claims")"
  expect "caller_kind" app "$(jq -r .defaults.metadata.caller_kind "$OUT/finance.claims")"

  t=$(entra_token "$CLIENT_HR_ID" "$CLIENT_HR_SECRET")
  st=$(exchange "$t"); expect "hr exchange status" 200 "$st"
  $JWT claims <<<"$(minted)" > "$OUT/hr.claims"
  expect "hr workspace" "$HR_WORKSPACE" "$(jq -r .portkey_workspace "$OUT/hr.claims")"
  expect "hr defaults.config_slug" "$HR_CONFIG_SLUG" "$(jq -r .defaults.config_slug "$OUT/hr.claims")"

  t=$(entra_token "$CLIENT_NOROLE_ID" "$CLIENT_NOROLE_SECRET")
  if [[ -z $t ]]; then expect "client without role: Entra refuses at the token endpoint" refused refused; jq -c '{error,error_description}' "$OUT/last-entra.json" | cut -c1-300 | tee -a "$OUT/run.log"
  else st=$(exchange "$t"); expect "client without role: broker status" 403 "$st"; cat "$OUT/ex.body" | tee -a "$OUT/run.log"; fi

  expect "no bearer token" 401 "$(exchange "")"
  expect "garbage bearer token" 401 "$(exchange garbage.token.here)"
  finish; }

mint_for() { local t; t=$(entra_token "$1" "$2"); exchange "$t" >/dev/null; minted; }

# gw_expect <label> <jwt> <expected option index>: status 200 and the answering target proves which config the token selected
gw_expect() {
  local st; st=$(gw "$2"); expect "$1: gateway status" 200 "$st"
  mask < "$OUT/gw.body" | head -c 300 | tee -a "$OUT/run.log"; echo
  grep -iE '^x-portkey-(last-used-option-index|trace-id)' "$OUT/gw.hdr" | tr -d '\r' | tee -a "$OUT/run.log"
  expect "$1: answering option index" "$3" "$(opt_index)"; }

scenario_modea-ok() {
  need_gw; start modea-ok
  gw_expect "finance app" "$(mint_for "$CLIENT_FINANCE_ID" "$CLIENT_FINANCE_SECRET")" "${FINANCE_OPTION_INDEX:-1}"
  gw_expect "hr app" "$(mint_for "$CLIENT_HR_ID" "$CLIENT_HR_SECRET")" "${HR_OPTION_INDEX:-2}"
  finish; }

scenario_modea-user() {
  need_gw; need PUBLIC_CLIENT_ID USER_ALICE_UPN USER_ALICE_PASSWORD USER_BOB_UPN USER_BOB_PASSWORD USER_CAROL_UPN USER_CAROL_PASSWORD; start modea-user
  local u n upn pw t idx
  for u in alice:${FINANCE_OPTION_INDEX:-1} bob:${HR_OPTION_INDEX:-2} carol:${FINANCE_OPTION_INDEX:-1}; do
    n=$(tr '[:lower:]' '[:upper:]' <<<"${u%%:*}"); upn=USER_${n}_UPN; pw=USER_${n}_PASSWORD; idx=${u##*:}
    t=$(user_token "${!upn}" "${!pw}"); expect "${u%%:*} got an Entra token" yes "$([[ -n $t ]] && echo yes || echo no)"
    exchange "$t" >/dev/null
    if [[ ${JIT_USER_ACCESS:-off} == on ]]; then gw_expect "${u%%:*}" "$(minted)" "$idx"
    else # user tokens are checked against workspace membership (app tokens are not): expect 403, code 033
      expect "${u%%:*}: gateway status (not a workspace member)" 403 "$(gw "$(minted)")"
      mask < "$OUT/gw.body" | head -c 300 | tee -a "$OUT/run.log"; echo
      expect "${u%%:*}: error code" 033 "$(grep -oE 'Error Code: [0-9]+' "$OUT/gw.body" | head -1 | grep -oE '[0-9]+')"
    fi
  done
  finish; }

scenario_negative() {
  need_gw; start negative
  local m st; m=$(mint_for "$CLIENT_FINANCE_ID" "$CLIENT_FINANCE_SECRET")
  for kind in payload sig kid; do
    st=$(gw "$($JWT tamper "$kind" <<<"$m")"); expect "tampered $kind" 401 "$st"; mask < "$OUT/gw.body" | head -c 300 | tee -a "$OUT/run.log"; echo
  done
  st=$(curl -sS -o "$OUT/gw.body" -w '%{http_code}' "$GATEWAY_URL/v1/messages" -H 'Content-Type: application/json' -d '{}'); expect "no token" 401 "$st"
  finish; }

scenario_mode-b() {
  need_gw; start mode-b
  local t st; t=$(entra_token "$CLIENT_FINANCE_ID" "$CLIENT_FINANCE_SECRET")
  st=$(gw "$t"); expect "raw Entra token at a gateway whose JWKS is the broker's" 401 "$st"
  mask < "$OUT/gw.body" | head -c 300 | tee -a "$OUT/run.log"; echo
  finish; }

scenario_rotation() {
  need_gw; need KEY_VAULT_NAME KEY_NAME; guard rotation "adds a key version to Key Vault $KEY_VAULT_NAME"; start rotation
  local old new st n t0 vers_before kid_old kid_new
  old=$(mint_for "$CLIENT_FINANCE_ID" "$CLIENT_FINANCE_SECRET"); kid_old=$($JWT header <<<"$old" | jq -r .kid)
  vers_before=$(az keyvault key list-versions --vault-name "$KEY_VAULT_NAME" -n "$KEY_NAME" --query 'length(@)' -o tsv)
  az keyvault key rotate --vault-name "$KEY_VAULT_NAME" -n "$KEY_NAME" --query 'key.kid' -o tsv >/dev/null
  new_ver=$(az keyvault key show --vault-name "$KEY_VAULT_NAME" -n "$KEY_NAME" --query 'key.kid' -o tsv | awk -F/ '{print $NF}')
  on_exit "az keyvault key set-attributes --vault-name '$KEY_VAULT_NAME' -n '$KEY_NAME' --version '$new_ver' --enabled false -o none"
  t0=$(date +%s)
  # The broker caches its key list for 5 minutes; poll until a token with the new kid appears.
  for ((n=0; n<40; n++)); do
    new=$(mint_for "$CLIENT_FINANCE_ID" "$CLIENT_FINANCE_SECRET"); kid_new=$($JWT header <<<"$new" | jq -r .kid)
    [[ $kid_new != "$kid_old" ]] && break; sleep 15
  done
  log "broker switched to new kid after $(( $(date +%s) - t0 ))s (poll $n)"
  expect "broker signs with the new key version" yes "$([[ $kid_new != "$kid_old" ]] && echo yes || echo no)"
  expect "JWKS lists both versions" 2 "$(curl -fsS "$BROKER_URL/.well-known/jwks.json" | jq '.keys|length')"
  $JWT verify "$BROKER_URL/.well-known/jwks.json" <<<"$old" >/dev/null 2>&1; expect "old token still verifies against JWKS" 0 $?
  # Gateway side: poll until the new kid is accepted, recording each attempt (gateway JWKS cache lag).
  for ((n=0; n<40; n++)); do st=$(gw "$new"); log "gateway poll $n: $(( $(date +%s) - t0 ))s status $st"; [[ $st == 200 ]] && break; sleep 15; done
  expect "gateway accepts token signed with the new kid" 200 "$st"
  expect "gateway still accepts the old token" 200 "$(gw "$old")"
  finish; }

# ---------------------------------------------------------------- dispatch (keep as is)
cmd=${1:-list}; shift || true; ARGS=("$@")
case $cmd in
  list)  for s in "${SCENARIOS[@]}"; do "describe_$s"; done ;;
  check) check ;;
  all)   for s in "${SCENARIOS[@]}"; do "scenario_$s"; done ;;
  *)     if declare -F "scenario_$cmd" >/dev/null; then "scenario_$cmd"; else sed -n '2,7p' "$0"; exit 2; fi ;;
esac

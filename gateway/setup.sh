#!/usr/bin/env bash
# Creates the gateway objects the token broker's policy points at, with airs-cli, and writes infra/policy.auto.tfvars
# (the Terraform "policy" variable, filled with the real workspace and config slugs). Run it BEFORE `terraform apply`.
#
# The upstream is an Anthropic-compatible mock (aigw-mock-anthropic) used as custom_host, so there is no integration and no
# provider key, and a 200 proves the request reached our upstream rather than a workspace default.
#
# Per role (finance, hr), all prefixed with PREFIX:
#   workspace            an existing one (workspace create failed on the lab tenants, so none are created): set WS_FINANCE_SLUG and WS_HR_SLUG. Their original defaults are saved to the state file.
#   configs a, b, c     a = single target (the workspace default). b and c are fallbacks whose first target(s) point at
#                        a path the mock answers 404 (the fallback fires on 404), so b is answered by target 1 and c by
#                        target 2. The gateway reports the answering target in the x-portkey-last-used-option-index
#                        response header (0, 1, 2), so the header names the config that applied without waiting for logs.
#                        Finance's token points at b, HR's at c.
# The workspace default (defaults.user_api_key_config) is set to config a, other defaults kept.
# Requests carry no x-portkey-config header: the JWT's defaults.config_slug decides the config.
#
# Env: UPSTREAM_HOST (required: the mock's base URL including its path token and /v1, for example
# https://<id>.lambda-url.<region>.on.aws/<token>/v1; never printed), AIRS_TENANT (airs-cli tenant, default the active
# one), PREFIX. Flags: --dry-run (creates nothing). State (ids and slugs, no secrets): gateway/.state.env.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_tenant

: "${WS_FINANCE_SLUG:?set WS_FINANCE_SLUG (slug of an existing workspace for the finance role)}"
: "${WS_HR_SLUG:?set WS_HR_SLUG (slug of an existing workspace for the hr role)}"
[[ -n "${UPSTREAM_HOST:-}" ]] || die "set UPSTREAM_HOST (the mock's base URL with its token and /v1)"
[[ "$UPSTREAM_HOST" =~ ^https://[^[:space:]]+/v1/?$ ]] || die "UPSTREAM_HOST should look like https://<host>/<token>/v1"
UPSTREAM_HOST="${UPSTREAM_HOST%/}"
# Same host with a wrong path token: the mock answers 404 for it.
BAD_HOST="${UPSTREAM_HOST%/*/v1}/no-such-token/v1"
TMP=$(umask 077 && mktemp -d)

make_config() { # <ws id> <name> <strategy json> <targets json>
  python3 -c 'import json,sys;print(json.dumps({"name":sys.argv[1],"workspace_id":sys.argv[2],"config":{"strategy":json.loads(sys.argv[3]),"targets":json.loads(sys.argv[4])}}))' \
    "$2" "$1" "$3" "$4" > "$TMP/cfg.json"
  run airs-cli aigateway configs create --file "$TMP/cfg.json" --output json >/dev/null
}

for role in finance hr; do
  R=$(printf '%s' "$role" | tr a-z A-Z)
  name="$PREFIX-$role"

  # ---- Workspace: an existing one (workspace create failed with 400 invalid_resource_type on the lab tenants, 2026-10-23), looked up by slug
  want_slug=$(printf '%s' "WS_${R}_SLUG"); want_slug="${!want_slug}"
  ws=$(airs-cli aigateway workspaces get "$want_slug" --output json 2>/dev/null || true)
  WS_ID=$(printf '%s' "$ws" | obj "d.get('id','')")
  WS_SLUG=$(printf '%s' "$ws" | obj "d.get('slug','')")
  [[ -n "$WS_ID" && "$WS_SLUG" == "$want_slug" ]] || die "workspace $want_slug not found"
  state_set "WORKSPACE_${R}_ID" "$WS_ID"; state_set "WORKSPACE_${R}_SLUG" "$WS_SLUG"
  log "$role workspace id=$WS_ID slug=$WS_SLUG"

  # ---- Configs a, b, c
  target() { python3 -c 'import json,sys;print(json.dumps({"provider":"anthropic","custom_host":sys.argv[1],"api_key":"mock-not-used"}))' "$1"; }
  good=$(target "$UPSTREAM_HOST"); bad=$(target "$BAD_HOST")
  cfgs() { airs-cli aigateway configs list --workspace "$WS_ID" --output json; }
  for spec in 'a|{"mode":"single"}|['"$good"']' \
              'b|{"mode":"fallback","on_status_codes":[400,404]}|['"$bad,$good"']' \
              'c|{"mode":"fallback","on_status_codes":[400,404]}|['"$bad,$bad,$good"']'; do
    IFS='|' read -r n strategy targets <<<"$spec"
    [[ -n "$(cfgs | find_by name "$name-$n")" ]] || { log "creating config $name-$n"; make_config "$WS_ID" "$name-$n" "$strategy" "$targets"; }
    c=$(cfgs | find_by name "$name-$n")
    state_set "CONFIG_${R}_$(printf '%s' "$n" | tr a-z A-Z)_ID" "$(printf '%s' "$c" | field id)"
    state_set "CONFIG_${R}_$(printf '%s' "$n" | tr a-z A-Z)_SLUG" "$(printf '%s' "$c" | field slug)"
  done

  # ---- Workspace default config = a (the baseline: option index 0)
  # The workspace is shared, so keep its other defaults: save the original defaults object once (teardown restores it)
  # and send the original merged with our config rather than a bare object.
  a_id=$(state_get "CONFIG_${R}_A_ID")
  orig=$(airs-cli aigateway workspaces get "$WS_ID" --output json | obj "json.dumps(d.get('defaults') or {})")
  [[ -n "$(state_get "DEFAULTS_${R}_ORIG")" ]] || state_set "DEFAULTS_${R}_ORIG" "$orig"
  cur=$(printf '%s' "$orig" | obj "d.get('user_api_key_config') or ''")
  if [[ "$cur" != "$a_id" ]]; then
    merged=$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);d["user_api_key_config"]=sys.argv[2];print(json.dumps({k:v for k,v in d.items() if v is not None}))' "$orig" "$a_id")
    run airs-cli aigateway workspaces update "$WS_ID" --defaults "$merged" --output json >/dev/null
  fi
done

(( DRY_RUN )) && { log "DRY-RUN done: nothing was created"; exit 0; }

# ---- Terraform policy: finance -> config b (index 1), hr -> config c (index 2)
OUT="$HERE/../infra/policy.auto.tfvars"
cat > "$OUT" <<TF
# Generated by gateway/setup.sh. Workspace and config slugs of the objects it created.
policy = {
  "Portkey.Workspace.Finance" = {
    workspace   = "$(state_get WORKSPACE_FINANCE_SLUG)"
    config_slug = "$(state_get CONFIG_FINANCE_B_SLUG)"
    scopes      = ["completions.write", "logs.view"]
    metadata    = { team = "finance" }
  }
  "Portkey.Workspace.HR" = {
    workspace   = "$(state_get WORKSPACE_HR_SLUG)"
    config_slug = "$(state_get CONFIG_HR_C_SLUG)"
    scopes      = ["completions.write"]
  }
}
TF
log "wrote $OUT"
log "workspaces: finance=$(state_get WORKSPACE_FINANCE_SLUG) hr=$(state_get WORKSPACE_HR_SLUG)"
log "expected option index: finance token -> 1, hr token -> 2, no claim -> 0"

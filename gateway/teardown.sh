#!/usr/bin/env bash
# Undoes gateway/setup.sh, by the ids in gateway/.state.env: restores the two workspaces' original defaults, deletes the six
# configs, then deletes infra/policy.auto.tfvars. The workspaces are existing ones and are not archived.
# Run `terraform destroy` first, or the broker keeps minting tokens for workspaces that no longer exist.
# Env: AIRS_TENANT (default the active tenant). Flags: --dry-run.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ -f "$STATE" ]] || die "no $STATE, nothing to remove"
use_tenant

del() { local what="$1"; shift; if run "$@" >/dev/null 2>&1; then log "removed $what"; else log "could not remove $what (already gone?)"; fi; }

# The workspaces are existing, shared ones: restore their original defaults first (so no default points at a deleted
# config), then delete our configs. The workspaces themselves are left alone.
for R in FINANCE HR; do
  id=$(state_get "WORKSPACE_${R}_ID"); orig=$(state_get "DEFAULTS_${R}_ORIG")
  [[ -n "$id" && -n "$orig" ]] || continue
  # The API rejects null values, so drop them; a key that was null (user_api_key_config) is cleared with "". Unverified:
  # the read-back below shows whether the default really went back.
  payload=$(python3 -c 'import json,sys;d=json.loads(sys.argv[1]);o={k:v for k,v in d.items() if v is not None};o.setdefault("user_api_key_config","");print(json.dumps(o))' "$orig")
  del "defaults of workspace $id" airs-cli aigateway workspaces update "$id" --defaults "$payload" --output json
  log "$R defaults now: $(airs-cli aigateway workspaces get "$id" --output json | obj "json.dumps(d.get('defaults'))")"
done
for R in FINANCE HR; do
  for n in A B C; do
    id=$(state_get "CONFIG_${R}_${n}_ID"); [[ -z "$id" ]] || del "config $id" airs-cli aigateway configs delete "$id" --force --output json
  done
done
(( DRY_RUN )) || rm -f "$HERE/../infra/policy.auto.tfvars"
echo "Leftover configs by prefix (should be empty):"
for R in FINANCE HR; do
  id=$(state_get "WORKSPACE_${R}_ID"); [[ -n "$id" ]] || continue
  airs-cli aigateway configs list --workspace "$id" --output json | jx "'\n'.join(c.get('name','') for c in d if c.get('name','').startswith('$PREFIX'))"
done
(( DRY_RUN )) || rm -f "$STATE"

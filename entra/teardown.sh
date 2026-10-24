#!/usr/bin/env bash
# Deletes every object that entra/setup.sh recorded in entra/.state.env. Works on a partial state file.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$HERE/.state.env"
[[ -f "$STATE" ]] || { echo "No $STATE, nothing to remove." >&2; exit 1; }
# shellcheck disable=SC1090
source "$STATE"

del() { # del <what> <command...>
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "deleted $what"; else echo "could not delete $what (already gone?)" >&2; fi
}

for v in USER_ALICE_ID USER_BOB_ID USER_CAROL_ID USER_DAVE_ID; do
  [[ -z "${!v:-}" ]] || del "user ${!v}" az ad user delete --id "${!v}"
done
for v in GROUP_FINANCE_ID GROUP_HR_ID; do
  [[ -z "${!v:-}" ]] || del "group ${!v}" az ad group delete --group "${!v}"
done
for v in PUBLIC_CLIENT_ID CLIENT_FINANCE_ID CLIENT_HR_ID CLIENT_NOROLE_ID ENTRA_CLIENT_ID; do
  [[ -z "${!v:-}" ]] || del "app ${!v}" az ad app delete --id "${!v}"
done

echo "Leftovers by prefix (should be empty):"
az ad app list --display-name "$PREFIX" --query "[].displayName" -o tsv
az ad user list --filter "startswith(displayName,'$PREFIX')" --query "[].userPrincipalName" -o tsv
az ad group list --display-name "$PREFIX" --query "[].displayName" -o tsv

rm -f "$STATE"

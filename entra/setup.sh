#!/usr/bin/env bash
# Creates the Entra objects the broker needs, using only the az CLI (no azuread Terraform provider).
# Needs: az logged in to the Entra tenant that will issue caller tokens, as Global Administrator (or
# Application Administrator + User Administrator + Groups Administrator).
# Writes entra/.state.env (mode 0600): tenant, app IDs, client secrets, test-user passwords. Never commit it.
#
# Created (all prefixed):
#   broker API app    app roles Portkey.Workspace.Finance / .HR, scope access_as_user, v2 tokens
#   3 client apps     finance, hr, norole (client credentials, app-only tokens)
#   1 public client   for user sign-in (ROPC / device code), consented to access_as_user
#   2 groups          finance, hr
#   4 users           alice (finance), bob (hr), carol (finance and hr), dave (no group, no role)
# Group-to-role assignment needs Entra ID P1. On Free the script falls back to assigning the roles to the users directly.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-aigw-entra-jwt-broker-e2e}"
UPN_PREFIX="${UPN_PREFIX:-aigwjwt-e2e}"
STATE="$HERE/.state.env"
GRAPH="https://graph.microsoft.com/v1.0"
SCOPE_ID="5b0a3d1e-6c0e-4f55-9a1d-1f0b7c2a00f1"

[[ -e "$STATE" ]] && { echo "$STATE exists. Run entra/teardown.sh first, or delete it if the objects are already gone." >&2; exit 1; }

TENANT_ID="$(az account show --query tenantId -o tsv)"
DOMAIN="$(az rest --method GET --url "$GRAPH/organization" --query "value[0].verifiedDomains[?isDefault].name | [0]" -o tsv)"
echo "Tenant: $TENANT_ID ($DOMAIN) as $(az account show --query user.name -o tsv)"

for n in "$PREFIX-broker" "$PREFIX-client-finance" "$PREFIX-client-hr" "$PREFIX-client-norole" "$PREFIX-public"; do
  [[ -z "$(az ad app list --display-name "$n" --query "[0].appId" -o tsv)" ]] || { echo "An app named $n already exists. Remove it or set PREFIX." >&2; exit 1; }
done

patch() { az rest --method PATCH --url "$GRAPH/$1" --headers "Content-Type=application/json" --body "$2" >/dev/null; }
post()  { az rest --method POST  --url "$GRAPH/$1" --headers "Content-Type=application/json" --body "$2" >/dev/null; }
role_id() { jq -r --arg v "$1" '.[] | select(.value==$v) | .id' "$HERE/appRoles.json"; }

# State is written as we go so a failed run can still be torn down.
umask 077
: > "$STATE"; chmod 600 "$STATE"
echo "PREFIX=$PREFIX" >> "$STATE"
echo "ENTRA_TENANT_ID=$TENANT_ID" >> "$STATE"
echo "ENTRA_DOMAIN=$DOMAIN" >> "$STATE"

# ---- Broker API app. v2 tokens must be requested explicitly, otherwise Entra issues v1 tokens
# (issuer sts.windows.net, different claims) and verification against the v2 issuer fails.
BROKER_APP_ID="$(az ad app create --display-name "$PREFIX-broker" --sign-in-audience AzureADMyOrg \
  --app-roles @"$HERE/appRoles.json" --query appId -o tsv)"
echo "ENTRA_CLIENT_ID=$BROKER_APP_ID" >> "$STATE"
echo "ENTRA_APP_ID_URI=api://$BROKER_APP_ID" >> "$STATE"
BROKER_OBJ_ID="$(az ad app show --id "$BROKER_APP_ID" --query id -o tsv)"
patch "applications/$BROKER_OBJ_ID" "$(jq -n --arg uri "api://$BROKER_APP_ID" --arg sid "$SCOPE_ID" '{
  identifierUris: [$uri],
  api: { requestedAccessTokenVersion: 2,
         oauth2PermissionScopes: [{ id: $sid, value: "access_as_user", type: "Admin", isEnabled: true,
           adminConsentDisplayName: "Call the Portkey token broker as the signed-in user",
           adminConsentDescription: "Lets the app call the token broker on behalf of the signed-in user." }] },
  optionalClaims: { accessToken: [{ name: "email" }] } }')"
BROKER_SP_ID="$(az ad sp create --id "$BROKER_APP_ID" --query id -o tsv)"
# Only callers with an app role assignment may get a token for the broker.
patch "servicePrincipals/$BROKER_SP_ID" '{"appRoleAssignmentRequired":true}'

# ---- Confidential clients (app-only tokens)
make_client() { # make_client <name> <state var prefix> [role value]
  local id sp secret
  id="$(az ad app create --display-name "$PREFIX-client-$1" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  sp="$(az ad sp create --id "$id" --query id -o tsv)"
  secret="$(az ad app credential reset --id "$id" --display-name e2e --years 1 --query password -o tsv)"
  { echo "$2_ID=$id"; echo "$2_SECRET=$secret"; } >> "$STATE"
  [[ -z "${3:-}" ]] || post "servicePrincipals/$sp/appRoleAssignments" \
    "{\"principalId\":\"$sp\",\"resourceId\":\"$BROKER_SP_ID\",\"appRoleId\":\"$(role_id "$3")\"}"
}
make_client finance CLIENT_FINANCE Portkey.Workspace.Finance
make_client hr CLIENT_HR Portkey.Workspace.HR
make_client norole CLIENT_NOROLE

# ---- Public client for user sign-in, consented to access_as_user for everyone
PUB_ID="$(az ad app create --display-name "$PREFIX-public" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
PUB_OBJ="$(az ad app show --id "$PUB_ID" --query id -o tsv)"
echo "PUBLIC_CLIENT_ID=$PUB_ID" >> "$STATE"
patch "applications/$PUB_OBJ" "$(jq -n --arg b "$BROKER_APP_ID" --arg sid "$SCOPE_ID" '{
  isFallbackPublicClient: true,
  requiredResourceAccess: [{ resourceAppId: $b, resourceAccess: [{ id: $sid, type: "Scope" }] }] }')"
PUB_SP="$(az ad sp create --id "$PUB_ID" --query id -o tsv)"
post oauth2PermissionGrants "$(jq -n --arg c "$PUB_SP" --arg r "$BROKER_SP_ID" \
  '{clientId:$c, consentType:"AllPrincipals", resourceId:$r, scope:"access_as_user"}')"

# ---- Groups and users
make_group() { # make_group <name> <state var>
  local gid; gid="$(az ad group create --display-name "$PREFIX-$1" --mail-nickname "$UPN_PREFIX-$1" --query id -o tsv)"
  echo "$2=$gid" >> "$STATE"; echo "$gid"
}
make_user() { # make_user <name> <state var prefix>
  local upn="$UPN_PREFIX-$1@$DOMAIN" pw uid
  pw="Aa1-$(openssl rand -hex 12)"
  uid="$(az ad user create --display-name "$PREFIX-$1" --user-principal-name "$upn" --mail-nickname "$UPN_PREFIX-$1" \
    --password "$pw" --force-change-password-next-sign-in false --query id -o tsv)"
  patch "users/$uid" "$(jq -n --arg m "$upn" '{mail:$m}')"
  { echo "$2_ID=$uid"; echo "$2_UPN=$upn"; echo "$2_PASSWORD=$pw"; } >> "$STATE"; echo "$uid"
}
G_FIN="$(make_group finance GROUP_FINANCE_ID)"
G_HR="$(make_group hr GROUP_HR_ID)"
U_ALICE="$(make_user alice USER_ALICE)"
U_BOB="$(make_user bob USER_BOB)"
U_CAROL="$(make_user carol USER_CAROL)"
make_user dave USER_DAVE >/dev/null
az ad group member add --group "$G_FIN" --member-id "$U_ALICE"
az ad group member add --group "$G_FIN" --member-id "$U_CAROL"
az ad group member add --group "$G_HR" --member-id "$U_BOB"
az ad group member add --group "$G_HR" --member-id "$U_CAROL"

# ---- Role assignment: groups on P1, users directly otherwise
assign() { # assign groups|users <object id> <role value>
  post "$1/$2/appRoleAssignments" \
    "{\"principalId\":\"$2\",\"resourceId\":\"$BROKER_SP_ID\",\"appRoleId\":\"$(role_id "$3")\"}"; }
if assign groups "$G_FIN" Portkey.Workspace.Finance 2>"$HERE/.assign.err"; then
  assign groups "$G_HR" Portkey.Workspace.HR
  echo "ROLE_ASSIGNMENT=group" >> "$STATE"
else
  echo "Group role assignment refused ($(tr '\n' ' ' < "$HERE/.assign.err" | cut -c1-160)); assigning roles to users directly."
  assign users "$U_ALICE" Portkey.Workspace.Finance
  assign users "$U_BOB" Portkey.Workspace.HR
  assign users "$U_CAROL" Portkey.Workspace.Finance
  assign users "$U_CAROL" Portkey.Workspace.HR
  echo "ROLE_ASSIGNMENT=user" >> "$STATE"
fi
rm -f "$HERE/.assign.err"

cat <<EOF

Done. Values for infra/terraform.tfvars:
  entra_tenant_id  = "$TENANT_ID"
  entra_client_id  = "$BROKER_APP_ID"
  entra_app_id_uri = "api://$BROKER_APP_ID"
Secrets and test-user passwords are in $STATE (mode 0600).
EOF

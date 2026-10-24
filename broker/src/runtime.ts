import { BrokerDeps } from "./broker";
import { createEntraVerifier } from "./entra";
import { KeyVaultKeys } from "./keyvault";
import { parsePolicy } from "./policy";

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing app setting ${name}`);
  return v;
}

let cached: { keys: KeyVaultKeys; deps: BrokerDeps } | undefined;

// Built on first use and reused across invocations, so the credential, key clients and JWKS cache survive.
export function runtime() {
  if (cached) return cached;
  const keys = new KeyVaultKeys(required("KEY_VAULT_URL"), required("KEY_NAME"));
  const audiences = [required("ENTRA_CLIENT_ID"), process.env.ENTRA_APP_ID_URI].filter(Boolean) as string[];
  const deps: BrokerDeps = {
    verifyEntra: createEntraVerifier({ tenantId: required("ENTRA_TENANT_ID"), audiences }),
    getSigner: () => keys.signer(),
    policy: parsePolicy(required("POLICY_JSON")),
    portkeyOrgId: required("PORTKEY_ORG_ID"),
    ttlSeconds: process.env.TOKEN_TTL_SECONDS ? Number(process.env.TOKEN_TTL_SECONDS) : undefined,
  };
  cached = { keys, deps };
  return cached;
}

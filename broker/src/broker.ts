import { callerFrom, EntraVerifier } from "./entra";
import { Policy, resolvePolicy } from "./policy";

export interface Signer {
  // Goes into the JWT header as `kid`; must match a key in the published JWKS.
  keyId: string;
  sign(signingInput: Buffer): Promise<Buffer>;
}

export interface BrokerDeps {
  verifyEntra: EntraVerifier;
  getSigner: () => Promise<Signer>;
  policy: Policy;
  portkeyOrgId: string;
  ttlSeconds?: number;
  now?: () => number;
}

export class BrokerError extends Error {
  constructor(public status: number, public code: string, public detail?: unknown) {
    super(code);
  }
}

const b64url = (b: Buffer | string) => Buffer.from(b).toString("base64url");

export async function exchange(entraToken: string, deps: BrokerDeps) {
  let payload;
  try {
    payload = await deps.verifyEntra(entraToken);
  } catch (err) {
    throw new BrokerError(401, "invalid_token", err);
  }

  const caller = callerFrom(payload);
  const resolved = resolvePolicy(deps.policy, caller.roles);
  if (!resolved) throw new BrokerError(403, "no_matching_role", { roles: caller.roles });

  const ttl = deps.ttlSeconds ?? 3600;
  const iat = (deps.now ?? (() => Math.floor(Date.now() / 1000)))();
  const { policy, role } = resolved;

  const claims: Record<string, unknown> = {
    portkey_oid: deps.portkeyOrgId,
    portkey_workspace: policy.workspace,
    sub: caller.subject,
    ...(caller.email ? { email_id: caller.email } : {}),
    scope: policy.scopes,
    defaults: {
      config_slug: policy.config_slug,
      config_id: policy.config_id ?? policy.config_slug,
      metadata: { ...policy.metadata, entra_role: role, caller_kind: caller.kind },
    },
    ...(policy.usage_limits !== undefined ? { usage_limits: policy.usage_limits } : {}),
    iat,
    exp: iat + ttl,
  };

  const signer = await deps.getSigner();
  const header = { alg: "RS256", typ: "JWT", kid: signer.keyId };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
  const signature = await signer.sign(Buffer.from(signingInput));

  return {
    access_token: `${signingInput}.${b64url(signature)}`,
    token_type: "Bearer" as const,
    expires_in: ttl,
  };
}

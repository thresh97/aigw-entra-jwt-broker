import { createRemoteJWKSet, jwtVerify, JWTPayload, JWTVerifyGetKey } from "jose";

export interface EntraConfig {
  tenantId: string;
  // Accepted `aud` values: the broker app's client ID and its Application ID URI.
  audiences: string[];
}

export type EntraVerifier = (token: string) => Promise<JWTPayload>;

export function entraIssuer(tenantId: string): string {
  return `https://login.microsoftonline.com/${tenantId}/v2.0`;
}

export function entraJwksUrl(tenantId: string): URL {
  return new URL(`https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`);
}

export function createEntraVerifier(cfg: EntraConfig, keys?: JWTVerifyGetKey): EntraVerifier {
  const getKey = keys ?? createRemoteJWKSet(entraJwksUrl(cfg.tenantId));
  return async (token) => {
    // A v1 token has issuer sts.windows.net and fails the issuer check. The broker app must set
    // api.requestedAccessTokenVersion = 2.
    const { payload } = await jwtVerify(token, getKey, {
      issuer: entraIssuer(cfg.tenantId),
      audience: cfg.audiences,
      algorithms: ["RS256"],
    });
    return payload;
  };
}

export interface Caller {
  roles: string[];
  // Stable identifier for the caller: user object ID, or the service principal's object ID for app tokens.
  subject: string;
  // Only set for user tokens.
  email?: string;
  kind: "user" | "app";
}

export function callerFrom(payload: JWTPayload): Caller {
  const roles = Array.isArray(payload.roles) ? (payload.roles as string[]) : [];
  const oid = (payload.oid as string | undefined) ?? payload.sub ?? "";
  // App-only tokens (client credentials) carry idtyp=app, no `scp`, and no user name claims.
  const isApp = payload.idtyp === "app" || (payload.scp === undefined && payload.preferred_username === undefined);
  const email = (payload.email ?? payload.preferred_username ?? payload.upn) as string | undefined;
  return { roles, subject: oid, email: isApp ? undefined : email, kind: isApp ? "app" : "user" };
}

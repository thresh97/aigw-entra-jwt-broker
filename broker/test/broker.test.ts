import assert from "node:assert/strict";
import { constants, createHash, generateKeyPairSync, KeyObject, privateEncrypt } from "node:crypto";
import { test } from "node:test";
import { createLocalJWKSet, decodeProtectedHeader, exportJWK, jwtVerify, SignJWT } from "jose";
import { BrokerError, exchange, Signer } from "../src/broker";
import { callerFrom, createEntraVerifier } from "../src/entra";
import { parsePolicy, resolvePolicy } from "../src/policy";

const TENANT = "00000000-0000-0000-0000-00000000aaaa";
const CLIENT_ID = "11111111-1111-1111-1111-111111111111";
const ORG = "org-test";

const POLICY = parsePolicy(
  JSON.stringify({
    "Portkey.Workspace.Finance": {
      workspace: "finance-prod",
      config_slug: "cfg-finance",
      scopes: ["completions.write", "logs.view"],
      metadata: { team: "finance" },
      usage_limits: [{ id: "ul-1", type: "cost", credit_limit: 10, status: "active" }],
    },
    "Portkey.Workspace.HR": {
      workspace: "hr",
      config_slug: "cfg-hr",
      config_id: "11111111-2222-3333-4444-555555555555",
      scopes: ["completions.write"],
    },
  }),
);

// Mimics Key Vault's sign(): the argument is a SHA-256 digest, and the result is a PKCS#1 v1.5 signature over it.
const SHA256_DIGEST_INFO = Buffer.from("3031300d060960864801650304020105000420", "hex");
function fakeKeyVaultSigner(privateKey: KeyObject, kid: string): Signer {
  return {
    keyId: kid,
    sign: async (input) => {
      return privateEncrypt(
        { key: privateKey, padding: constants.RSA_PKCS1_PADDING },
        Buffer.concat([SHA256_DIGEST_INFO, createHash("sha256").update(input).digest()]),
      );
    },
  };
}

// The defect in the original handoff code: handing the message itself to a digest-only API.
function brokenSigner(privateKey: KeyObject, kid: string): Signer {
  return {
    keyId: kid,
    sign: async (input) => {
      assert.equal(input.length, 32, "Key Vault sign() expects a 32-byte SHA-256 digest");
      return Buffer.alloc(256);
    },
  };
}

const gatewayKeys = generateKeyPairSync("rsa", { modulusLength: 2048 });
const entraKeys = generateKeyPairSync("rsa", { modulusLength: 2048 });

async function entraToken(claims: Record<string, unknown>, opts: { exp?: string; iss?: string; aud?: string } = {}) {
  return new SignJWT(claims)
    .setProtectedHeader({ alg: "RS256", kid: "entra-key" })
    .setIssuer(opts.iss ?? `https://login.microsoftonline.com/${TENANT}/v2.0`)
    .setAudience(opts.aud ?? CLIENT_ID)
    .setIssuedAt()
    .setExpirationTime(opts.exp ?? "5m")
    .sign(entraKeys.privateKey);
}

async function deps(signer: Signer) {
  const jwk = { ...(await exportJWK(entraKeys.publicKey)), kid: "entra-key", alg: "RS256", use: "sig" };
  return {
    verifyEntra: createEntraVerifier({ tenantId: TENANT, audiences: [CLIENT_ID] }, createLocalJWKSet({ keys: [jwk] })),
    getSigner: async () => signer,
    policy: POLICY,
    portkeyOrgId: ORG,
  };
}

async function verifyPortkeyToken(token: string, kid: string, publicKey: KeyObject) {
  const jwk = { ...(await exportJWK(publicKey)), kid, alg: "RS256", use: "sig" };
  return jwtVerify(token, createLocalJWKSet({ keys: [jwk] }), { algorithms: ["RS256"] });
}

test("minted token verifies against the published public key (Key Vault digest semantics)", async () => {
  const d = await deps(fakeKeyVaultSigner(gatewayKeys.privateKey, "ver1"));
  const t = await entraToken({ roles: ["Portkey.Workspace.Finance"], oid: "app-oid", idtyp: "app" });
  const out = await exchange(t, d);
  const header = decodeProtectedHeader(out.access_token);
  assert.deepEqual(header, { alg: "RS256", typ: "JWT", kid: "ver1" });
  const { payload } = await verifyPortkeyToken(out.access_token, "ver1", gatewayKeys.publicKey);
  assert.equal(payload.portkey_oid, ORG);
  assert.equal(payload.portkey_workspace, "finance-prod");
  assert.deepEqual(payload.scope, ["completions.write", "logs.view"]);
  assert.equal((payload.defaults as any).config_slug, "cfg-finance");
  assert.equal((payload.defaults as any).config_id, "cfg-finance");
  assert.deepEqual(payload.usage_limits, [{ id: "ul-1", type: "cost", credit_limit: 10, status: "active" }]);
  assert.equal(payload.exp! - payload.iat!, 3600);
});

test("the original handoff signing call (message instead of digest) is caught", async () => {
  const d = await deps(brokenSigner(gatewayKeys.privateKey, "ver1"));
  const t = await entraToken({ roles: ["Portkey.Workspace.Finance"], oid: "o" });
  await assert.rejects(exchange(t, d), /32-byte SHA-256 digest/);
});

test("caller with no matching role is refused, not given a default tier", async () => {
  const d = await deps(fakeKeyVaultSigner(gatewayKeys.privateKey, "ver1"));
  for (const roles of [[], ["Some.Other.Role"]]) {
    const t = await entraToken({ roles, oid: "o" });
    await assert.rejects(exchange(t, d), (e: BrokerError) => e.status === 403 && e.code === "no_matching_role");
  }
  const noRolesClaim = await entraToken({ oid: "o" });
  await assert.rejects(exchange(noRolesClaim, d), (e: BrokerError) => e.status === 403);
});

test("Entra token problems are 401 invalid_token", async () => {
  const d = await deps(fakeKeyVaultSigner(gatewayKeys.privateKey, "ver1"));
  const base = { roles: ["Portkey.Workspace.Finance"], oid: "o" };
  const bad = [
    await entraToken(base, { exp: "-1m" }),
    await entraToken(base, { aud: "22222222-2222-2222-2222-222222222222" }),
    await entraToken(base, { iss: "https://sts.windows.net/" + TENANT + "/" }),
    "not-a-jwt",
  ];
  for (const t of bad) {
    await assert.rejects(exchange(t, d), (e: BrokerError) => e.status === 401 && e.code === "invalid_token");
  }
});

test("Entra token signed by another key is refused", async () => {
  const d = await deps(fakeKeyVaultSigner(gatewayKeys.privateKey, "ver1"));
  const other = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const t = await new SignJWT({ roles: ["Portkey.Workspace.Finance"], oid: "o" })
    .setProtectedHeader({ alg: "RS256", kid: "entra-key" })
    .setIssuer(`https://login.microsoftonline.com/${TENANT}/v2.0`)
    .setAudience(CLIENT_ID)
    .setExpirationTime("5m")
    .sign(other.privateKey);
  await assert.rejects(exchange(t, d), (e: BrokerError) => e.status === 401);
});

test("role precedence follows policy order, not token order", () => {
  const r = resolvePolicy(POLICY, ["Portkey.Workspace.HR", "Portkey.Workspace.Finance"]);
  assert.equal(r?.role, "Portkey.Workspace.Finance");
});

test("user and app callers are told apart", () => {
  const app = callerFrom({ oid: "sp-oid", sub: "sp-sub", idtyp: "app", roles: ["r"] });
  assert.deepEqual(app, { roles: ["r"], subject: "sp-oid", email: undefined, kind: "app" });
  const user = callerFrom({ oid: "u-oid", sub: "u-sub", preferred_username: "a@example.com", scp: "access", roles: ["r"] });
  assert.equal(user.kind, "user");
  assert.equal(user.email, "a@example.com");
});

test("app tokens carry sub but no email_id; user tokens carry both", async () => {
  const d = await deps(fakeKeyVaultSigner(gatewayKeys.privateKey, "ver1"));
  const appTok = await exchange(await entraToken({ roles: ["Portkey.Workspace.HR"], oid: "sp-oid", idtyp: "app" }), d);
  const appClaims = (await verifyPortkeyToken(appTok.access_token, "ver1", gatewayKeys.publicKey)).payload;
  assert.equal(appClaims.sub, "sp-oid");
  assert.equal(appClaims.email_id, undefined);
  assert.equal((appClaims.defaults as any).metadata.caller_kind, "app");

  const userTok = await exchange(
    await entraToken({ roles: ["Portkey.Workspace.HR"], oid: "u-oid", preferred_username: "a@example.com", scp: "access" }),
    d,
  );
  const userClaims = (await verifyPortkeyToken(userTok.access_token, "ver1", gatewayKeys.publicKey)).payload;
  assert.equal(userClaims.email_id, "a@example.com");
  assert.equal((userClaims.defaults as any).metadata.entra_role, "Portkey.Workspace.HR");
});

test("rotation: a token signed with the new kid fails against a JWKS that only has the old one", async () => {
  const newKeys = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const d = await deps(fakeKeyVaultSigner(newKeys.privateKey, "ver2"));
  const t = await entraToken({ roles: ["Portkey.Workspace.Finance"], oid: "o" });
  const out = await exchange(t, d);
  await assert.rejects(verifyPortkeyToken(out.access_token, "ver1", gatewayKeys.publicKey));
  const both = createLocalJWKSet({
    keys: [
      { ...(await exportJWK(gatewayKeys.publicKey)), kid: "ver1", alg: "RS256" },
      { ...(await exportJWK(newKeys.publicKey)), kid: "ver2", alg: "RS256" },
    ],
  });
  await jwtVerify(out.access_token, both);
});

test("policy validation rejects incomplete roles", () => {
  assert.throws(() => parsePolicy(JSON.stringify({ r: { workspace: "w", config_slug: "c", scopes: [] } })));
  assert.throws(() => parsePolicy(JSON.stringify({ r: { workspace: "w", scopes: ["a"] } })));
});

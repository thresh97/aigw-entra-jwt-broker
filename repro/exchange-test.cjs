// Live test of the broker's /token/exchange. Node 18+, no dependencies. Run it where the broker is reachable.
// Reads its configuration from the environment (names below); prints decoded claims, never raw tokens or secrets.
const crypto = require("node:crypto");
const env = (k) => { const v = process.env[k]; if (!v) throw new Error(`missing env ${k}`); return v; };
const b64 = (s) => Buffer.from(s, "base64url");
const decode = (jwt) => { const [h, p] = jwt.split("."); return { header: JSON.parse(b64(h)), payload: JSON.parse(b64(p)) }; };

const tenant = env("ENTRA_TENANT_ID"), api = env("ENTRA_APP_ID_URI"), base = env("BROKER_BASE_URL"), oid = env("PORTKEY_ORG_ID");
const tokenUrl = `https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token`;

async function entra(form) {
  const r = await fetch(tokenUrl, { method: "POST", body: new URLSearchParams(form) });
  const j = await r.json();
  if (!r.ok) return { error: `${j.error}: ${(j.error_description ?? "").split("\r\n")[0]}`, codes: j.error_codes };
  return { token: j.access_token };
}
const app = (id, secret) => entra({ grant_type: "client_credentials", client_id: id, client_secret: secret, scope: `${api}/.default` });
const user = (upn, pw) => entra({ grant_type: "password", client_id: env("PUBLIC_CLIENT_ID"), username: upn, password: pw, scope: `${api}/access_as_user` });
const exchange = async (token, method = "POST") => {
  const r = await fetch(`${base}/token/exchange`, { method, headers: token ? { Authorization: `Bearer ${token}` } : {} });
  let body; try { body = await r.json(); } catch { body = null; }
  return { status: r.status, body };
};

const expectations = {
  finance: { workspace: env("FINANCE_WORKSPACE"), config: env("FINANCE_CONFIG_SLUG"), scopes: ["completions.write", "logs.view"], team: "finance" },
  hr: { workspace: env("HR_WORKSPACE"), config: env("HR_CONFIG_SLUG"), scopes: ["completions.write"] },
};

(async () => {
  const jwks = await (await fetch(`${base}/.well-known/jwks.json`)).json();
  const results = { when: new Date().toISOString(), jwks_kids: jwks.keys.map((k) => k.kid), cases: [] };
  const record = (name, extra) => { results.cases.push({ name, ...extra }); };

  function verifyMinted(access_token) {
    const { header, payload } = decode(access_token);
    const jwk = jwks.keys.find((k) => k.kid === header.kid);
    const [h, p, s] = access_token.split(".");
    const sigOk = !!jwk && crypto.verify("RSA-SHA256", Buffer.from(`${h}.${p}`), crypto.createPublicKey({ key: jwk, format: "jwk" }), b64(s));
    return { header, payload, sigOk, oidOk: payload.portkey_oid === oid };
  }
  const exp = (kind) => expectations[kind];
  function check(kind, v) {
    const e = exp(kind), p = v.payload, d = p.defaults ?? {};
    const problems = [];
    if (!v.sigOk) problems.push("signature does not verify against live JWKS");
    if (!v.oidOk) problems.push("portkey_oid mismatch");
    if (v.header.alg !== "RS256") problems.push(`alg ${v.header.alg}`);
    if (p.portkey_workspace !== e.workspace) problems.push(`workspace ${p.portkey_workspace}`);
    if (d.config_slug !== e.config) problems.push(`config_slug ${d.config_slug}`);
    if (JSON.stringify([...(Array.isArray(p.scope) ? p.scope : String(p.scope ?? "").split(" "))].sort()) !== JSON.stringify([...e.scopes].sort())) problems.push(`scope ${p.scope}`);
    if (e.team && d.metadata?.team !== e.team) problems.push(`metadata ${JSON.stringify(d.metadata)}`);
    return problems;
  }

  for (const [kind, id, secret] of [["finance", "CLIENT_FINANCE_ID", "CLIENT_FINANCE_SECRET"], ["hr", "CLIENT_HR_ID", "CLIENT_HR_SECRET"]]) {
    const t = await app(env(id), env(secret));
    if (t.error) { record(`app:${kind}`, { entra_error: t.error }); continue; }
    const entraClaims = decode(t.token).payload;
    const r = await exchange(t.token);
    if (r.status !== 200) { record(`app:${kind}`, { entra_roles: entraClaims.roles, status: r.status, body: r.body }); continue; }
    const v = verifyMinted(r.body.access_token);
    record(`app:${kind}`, { entra_roles: entraClaims.roles, status: 200, expires_in: r.body.expires_in, header: v.header, minted: v.payload, problems: check(kind, v) });
  }

  { const t = await app(env("CLIENT_NOROLE_ID"), env("CLIENT_NOROLE_SECRET"));
    if (t.error) record("app:norole", { entra_error: t.error, note: "Entra itself refused (appRoleAssignmentRequired)" });
    else { const r = await exchange(t.token); record("app:norole", { entra_roles: decode(t.token).payload.roles ?? null, status: r.status, body: r.body }); } }

  record("no bearer", await exchange(null));
  record("garbage bearer", await exchange("not.a.jwt"));
  record("wrong method GET", await exchange(null, "GET"));

  for (const u of ["ALICE", "BOB", "CAROL", "DAVE"]) {
    const t = await user(env(`USER_${u}_UPN`), env(`USER_${u}_PASSWORD`));
    if (t.error) { record(`user:${u.toLowerCase()}`, { entra_error: t.error, codes: t.codes }); continue; }
    const c = decode(t.token).payload;
    const identity = { ver: c.ver, roles: c.roles ?? null, scp: c.scp, groups: c.groups ?? null, has_email: !!c.email, has_preferred_username: !!c.preferred_username, has_upn: !!c.upn, oid_present: !!c.oid, idtyp: c.idtyp ?? null };
    const r = await exchange(t.token);
    if (r.status !== 200) { record(`user:${u.toLowerCase()}`, { entra_claims: identity, status: r.status, body: r.body }); continue; }
    const v = verifyMinted(r.body.access_token);
    const ident = Object.fromEntries(Object.entries(v.payload).filter(([k]) => ["sub", "email", "name", "user_id", "preferred_username", "iss", "aud", "exp", "iat"].includes(k)));
    record(`user:${u.toLowerCase()}`, { entra_claims: identity, status: 200, sigOk: v.sigOk, oidOk: v.oidOk, minted: v.payload, identity_claims: ident });
  }

  require("node:fs").writeFileSync(process.argv[2] ?? "results.json", JSON.stringify(results, null, 2));
  for (const c of results.cases) console.log(c.name.padEnd(16), c.status ?? c.entra_error, c.problems?.length ? "PROBLEMS: " + c.problems.join("; ") : c.problems ? "ok" : (c.body ? JSON.stringify(c.body) : ""));
})().catch((e) => { console.error(e); process.exit(1); });

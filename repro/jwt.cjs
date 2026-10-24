#!/usr/bin/env node
// Token helper for run.sh. Reads a JWT on stdin. Never prints the token itself except from `tamper`.
//   jwt.cjs header|claims            print the decoded header or payload as JSON
//   jwt.cjs verify <jwks-url>        verify RS256 signature and exp against a live JWKS; print payload, exit 1 on failure
//   jwt.cjs tamper payload|sig|kid   print a modified copy of the token (signature left as is, or damaged)
const path = require("node:path");
const { createRequire } = require("node:module");
const fs = require("node:fs");

const [cmd, arg] = process.argv.slice(2);
const token = fs.readFileSync(0, "utf8").trim();
const [h, p, s] = token.split(".");
const dec = (x) => JSON.parse(Buffer.from(x, "base64url").toString("utf8"));
const enc = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");

(async () => {
  if (cmd === "header") return console.log(JSON.stringify(dec(h)));
  if (cmd === "claims") return console.log(JSON.stringify(dec(p)));
  if (cmd === "tamper") {
    if (arg === "payload") return console.log([h, enc({ ...dec(p), portkey_workspace: "tampered" }), s].join("."));
    if (arg === "kid") return console.log([enc({ ...dec(h), kid: "no-such-kid" }), p, s].join("."));
    if (arg === "sig") return console.log([h, p, (s[0] === "A" ? "B" : "A") + s.slice(1)].join("."));
    throw new Error("tamper payload|sig|kid");
  }
  if (cmd === "verify") {
    const req = createRequire(path.join(__dirname, "../broker/package.json"));
    const jose = req("jose");
    const jwks = jose.createRemoteJWKSet(new URL(arg), { cooldownDuration: 0, cacheMaxAge: 0 });
    const { payload } = await jose.jwtVerify(token, jwks, { algorithms: ["RS256"] });
    return console.log(JSON.stringify(payload));
  }
  throw new Error("unknown command");
})().catch((e) => {
  console.error(e.code || e.message);
  process.exit(1);
});

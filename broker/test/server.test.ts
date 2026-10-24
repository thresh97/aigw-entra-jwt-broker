import { strict as assert } from "node:assert";
import { createServer, Server } from "node:http";
import { AddressInfo } from "node:net";
import { after, before, test } from "node:test";
import { handle } from "../src/server";

let server: Server;
let base: string;

before(async () => {
  server = createServer((req, res) => void handle(req, res));
  await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
});
after(() => new Promise<void>((ok) => server.close(() => ok())));

test("healthz answers without any broker settings", async () => {
  const r = await fetch(`${base}/healthz`);
  assert.equal(r.status, 200);
});

test("exchange without a bearer token is 401 missing_bearer_token", async () => {
  const r = await fetch(`${base}/token/exchange`, { method: "POST" });
  assert.equal(r.status, 401);
  assert.deepEqual(await r.json(), { error: "missing_bearer_token" });
});

test("exchange and jwks reject the wrong method, unknown paths are 404", async () => {
  assert.equal((await fetch(`${base}/token/exchange`)).status, 405);
  assert.equal((await fetch(`${base}/.well-known/jwks.json`, { method: "POST" })).status, 405);
  assert.equal((await fetch(`${base}/nope`)).status, 404);
});

test("misconfigured broker answers 503 on jwks and a generic 500 on exchange, never the cause", async () => {
  const saved = process.env.KEY_VAULT_URL;
  delete process.env.KEY_VAULT_URL;
  try {
    assert.equal((await fetch(`${base}/.well-known/jwks.json`)).status, 503);
    const r = await fetch(`${base}/token/exchange`, { method: "POST", headers: { Authorization: "Bearer abc" } });
    assert.equal(r.status, 500);
    assert.deepEqual(await r.json(), { error: "internal_error" });
  } finally {
    if (saved !== undefined) process.env.KEY_VAULT_URL = saved;
  }
});

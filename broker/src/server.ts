import { createServer, IncomingMessage, ServerResponse } from "node:http";
import { BrokerError, exchange } from "./broker";
import { runtime } from "./runtime";

function send(res: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}) {
  res.writeHead(status, { "Content-Type": "application/json", ...headers });
  res.end(JSON.stringify(body));
}

// The Entra token in the Authorization header is the credential, so the endpoints themselves are anonymous.
export async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const path = new URL(req.url ?? "/", "http://localhost").pathname;

  if (path === "/healthz") return send(res, 200, { status: "ok" });

  if (path === "/.well-known/jwks.json") {
    if (req.method !== "GET") return send(res, 405, { error: "method_not_allowed" });
    try {
      return send(res, 200, await runtime().keys.jwks(), { "Cache-Control": "public, max-age=300" });
    } catch (err) {
      console.error("jwks failed", err);
      return send(res, 503, { error: "jwks_unavailable" });
    }
  }

  if (path === "/token/exchange") {
    if (req.method !== "POST") return send(res, 405, { error: "method_not_allowed" });
    const auth = req.headers.authorization ?? "";
    if (!auth.toLowerCase().startsWith("bearer ")) return send(res, 401, { error: "missing_bearer_token" });
    try {
      const body = await exchange(auth.slice(7).trim(), runtime().deps);
      return send(res, 200, body, { "Cache-Control": "no-store" });
    } catch (err) {
      if (err instanceof BrokerError) {
        console.warn(`exchange refused: ${err.code}`, err.detail);
        return send(res, err.status, { error: err.code });
      }
      console.error("exchange failed", err);
      return send(res, 500, { error: "internal_error" });
    }
  }

  return send(res, 404, { error: "not_found" });
}

if (require.main === module) {
  const server = createServer((req, res) => {
    handle(req, res).catch((err) => {
      console.error("unhandled", err);
      if (!res.headersSent) send(res, 500, { error: "internal_error" });
    });
  });
  const port = Number(process.env.PORT ?? 8080);
  server.listen(port, () => console.log(`broker listening on ${port}`));
  process.on("SIGTERM", () => server.close(() => process.exit(0)));
}

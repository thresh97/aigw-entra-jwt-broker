# aigw-entra-jwt-broker

A small token broker that turns a Microsoft Entra ID token (carrying an app role) into a signed Portkey Mode A JWT for a hybrid AI Gateway. Entra can't emit nested claims such as `defaults.config_slug` or `usage_limits`, and one Entra token can't pick a Portkey workspace, so the broker maps the caller's app role to a workspace, a config, scopes and metadata and signs the result with an RS256 key in Azure Key Vault. Use it when a hybrid gateway must authenticate Entra identities (users or apps) and route each team to its own workspace and config, with no Portkey API keys handed out.

> **Disclaimer:** This is a simple, art-of-the-possible example. It is **not** an official Portkey or Microsoft project, it is **not** a recommended or supported production design, and it comes with **no support**. Use it at your own risk, under the [MIT License](LICENSE).

| Part | What it is | Where |
|---|---|---|
| Entra objects | Broker API app with app roles `Portkey.Workspace.Finance` and `Portkey.Workspace.HR`, three client-credentials apps, a public client for user sign-in (device code, and browser sign-in with PKCE on the loopback redirect `http://127.0.0.1`), groups and test users | `entra/` (az CLI and Microsoft Graph, no azuread Terraform provider) |
| Broker | Node 20 service: `POST /token/exchange`, `GET /.well-known/jwks.json`, `GET /healthz`. Validates the Entra token, picks a policy by role, signs with Key Vault | `broker/`, public container image |
| Azure | Container App (HTTPS, system-assigned identity), Key Vault with an RSA-2048 signing key (Crypto User for the identity) | `infra/` (Terraform, azurerm only) |
| Gateway objects | Per role: a workspace, a config (a fallback config that identifies itself in a response header) and the policy that names them | `gateway/` (airs-cli) |
| Gateway setting | Org JWT auth: the broker's JWKS URL added to the org's JWKS URL list, `JWT_ENABLED=ON` on the gateway | Admin Settings (web UI) |

```
caller --Entra token--> broker --(Key Vault sign)--> Portkey Mode A JWT --Bearer--> hybrid gateway --> upstream
                          ^ validates against Entra's JWKS           gateway validates against the broker's JWKS
```

Design background, with the original handoff's claims corrected after the tests: [docs/design.md](docs/design.md), with the flow diagram in [docs/flow.svg](docs/flow.svg).

The broker is stateless apart from the key. The policy (role to workspace, `config_slug`, scopes, metadata, optional `usage_limits`) is a Terraform variable that ends up in one environment variable. Roles are checked in the policy's key order, so a caller holding several roles gets the first matching one.

## What you need

- A hybrid AI Gateway (2.29.0 tested) with `JWT_ENABLED=ON`, and the right to edit the org's JWT settings (Admin Settings, Organisation, Authentication) and to use two workspaces.
- An Entra tenant where you can register apps and assign app roles (Global Administrator, or Application Administrator plus User and Groups Administrator), and `az login` into it. Microsoft's doc says assigning roles to groups needs Entra ID P1, but it worked on a Free tenant (see Findings); the setup script still falls back to assigning roles to users directly if the tenant refuses.
- An Azure subscription for the Container App and Key Vault. It may belong to a different tenant than Entra.
- The tools: `az`, `terraform` 1.6+, `jq`, `node` 20, `curl`, `airs-cli` (for `gateway/`), and an x86 Docker host reachable over ssh if you build the image yourself (`broker/publish.sh`).
- An upstream the gateway can reach. The tests use an Anthropic-compatible mock as `custom_host`, so no provider key is needed and a 200 proves the request reached that upstream.

A Container App needs no storage account and no registry of your own (the image is pulled anonymously from a public package), which matters in subscriptions whose policy restricts storage accounts or registries.

## 1. Build

1. Entra: `entra/setup.sh` creates the apps, roles, groups and test users and writes `entra/.state.env` (mode 600, never commit it). `entra/teardown.sh` removes them.
2. Gateway objects: `WS_FINANCE_SLUG=<slug> WS_HR_SLUG=<slug> UPSTREAM_HOST=https://<mock>/<path>/v1 gateway/setup.sh` (`--dry-run` first). It uses two existing workspaces, creates configs `a` (single target, the workspace default), `b` and `c` (fallbacks that reach the upstream as target 1 and target 2) and writes `infra/policy.auto.tfvars`. Config `b` goes to finance and `c` to HR, so the `x-portkey-last-used-option-index` response header says which config a token selected.
3. Image: `BUILD_HOST=<ssh target> broker/publish.sh` builds and pushes `ghcr.io/<owner>/aigw-entra-jwt-broker:<tag>` (the tag is a hash of the sources) and prints the reference. The package must be public so Container Apps can pull it anonymously.
4. Azure: `cp infra/terraform.tfvars.example infra/terraform.tfvars`, fill it in, then `infra/deploy.sh` (pass 1: Key Vault, key, identity, environment) and `infra/deploy.sh <image>` (pass 2: the Container App). `terraform output` prints `exchange_url` and `jwks_url`.
5. Gateway: add the broker's `jwks_url` to the org's JWKS URL setting. The field takes a comma-separated list, so an existing IdP's JWKS URL can stay.

## 2. Quick check

```
repro/run.sh check          # read-only preflight
repro/run.sh broker         # the broker alone, no gateway needed
```

## 3. End-to-end test

`repro/run.sh all --yes` runs the scenarios below. Each one self-judges (`PASS`, `CHANGED`, `ERROR`) and writes `repro/results/<date>-<scenario>/`.

| Scenario | What it checks |
|---|---|
| `broker` | Exchange for app and user callers, claims, offline verification against the live JWKS, error paths |
| `modea-ok` | Minted app tokens accepted by the gateway, each selecting its own config |
| `modea-user` | The same for user tokens, including the workspace membership check |
| `negative` | Tampered payload or signature, wrong `kid`, no token: the gateway's exact error text |
| `mode-b` | A raw Entra token sent straight to the gateway, with Entra's JWKS not configured on the org |
| `rotation` | A second key version in the JWKS (not run, see Findings) |

## 4. Teardown

`terraform destroy` in `infra/`, then `gateway/teardown.sh` (meant to restore the workspace defaults it changed and remove its configs; the restore step is unverified), then `entra/teardown.sh`, then remove the broker's JWKS URL from the org setting. Confirm nothing with the prefix is left.

## Re-run

For a person or a basic agent, no code changes. The scenarios send requests to the broker, Entra and the gateway; they create no objects (only `entra/setup.sh`, `gateway/setup.sh` and `infra/deploy.sh` do).

1. Prerequisites: the tools above, network access from the host to the broker, the gateway and `login.microsoftonline.com`, and `npm ci` in `broker/`. If the gateway's load balancer has a source-IP allow-list, run from an allowed host.
2. `cp repro/env.example repro/env` and fill it in. Set `JIT_USER_ACCESS` to match the gateway's `JWT_JIT_USER_ACCESS`.
3. `repro/run.sh check`.
4. Run `broker`, `modea-ok`, `modea-user`, `negative` and `mode-b` (about 5 minutes together). `repro/run.sh all` also runs `rotation`, which adds a Key Vault key version and needs `--yes`.
5. Read `repro/results/<date>-<scenario>/summary.txt`. `PASS`: matches Findings. `CHANGED`: behavior differs from Findings, most likely a gateway change, so compare the observed line with the Gateway table below. `ERROR`: the run broke; fix the environment, not the scripts.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| A native app's browser sign-in (authorization code with PKCE, redirect to `http://127.0.0.1:<port>/`) ends on an Entra page with `AADSTS500113: No reply address is registered for the application.` | The public client has no redirect URI. `entra/setup.sh` from before 2026-10-24 registered none, so only device code and ROPC worked | Add `http://127.0.0.1` on the "Mobile and desktop applications" platform (Entra ignores the port on loopback). In the portal: App registrations, `<prefix>-public`, Authentication, Add a platform. Or with az, see below. The device code flow is unaffected and works either way |
| Sign-in refused with `AADSTS501051` (app) or `AADSTS50105` (user) | The caller holds no app role on the broker, and its enterprise application requires assignment | Assign a role (directly or through a group), see Findings |

Adding the redirect URI with az to an existing lab (this replaces the public client's redirect URI list, so include any URIs it already has):

```
obj=$(az ad app list --display-name "<prefix>-public" --query "[0].id" -o tsv)
az rest --method GET --url "https://graph.microsoft.com/v1.0/applications/$obj?\$select=publicClient"   # current list
az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$obj" \
  --headers "Content-Type=application/json" --body '{"publicClient":{"redirectUris":["http://127.0.0.1"]}}'
```

## Findings

Tested 2026-10-23 (and the public client's redirect URI on 2026-10-24, see Entra side) against hybrid gateway 2.29.0 (EKS) with the broker running as an Azure Container App and a Key Vault RSA-2048 key. Not tested on SaaS. Behavior may change in later releases. The Portkey JWT doc (portkey.ai/docs, org-management, jwt) was read the same day.

### Entra side

- App roles reach the token as the `roles` claim for both caller kinds: client-credentials (app) tokens and delegated user tokens. The broker puts the user's email into `email_id` for user tokens and uses the Entra object id as `sub`; app tokens carry no email.
- Roles assigned to a group reached the user's token. The lab tenant is on the Free tier (noted by the operator after the run; the script doesn't record the tier) and accepted the group assignment, although Microsoft's doc says P1 is needed. Other tenants and later Entra changes may differ.
- With "assignment required" on the broker's enterprise application, Entra itself refuses a caller that holds no role before the broker sees it (apps: `AADSTS501051`, users: `AADSTS50105`). The broker's own 403 `no_matching_role` path is therefore covered by unit tests only.
- A caller holding both roles gets the policy of the first role in the policy's key order.
- Password (ROPC) sign-in works for test users without MFA. It is a test convenience only.
- 2026-10-24: a native client's browser sign-in (PKCE, loopback redirect) against the public client failed with `AADSTS500113` because no redirect URI was registered; device code sign-in on the same client worked. `http://127.0.0.1` (Mobile and desktop applications) was then added by Graph PATCH and reads back from Graph, and the same client's browser sign-in then worked (reported by the operator; no output kept). An unauthenticated authorize request can't show the fix: Entra returns its sign-in page for any redirect URI, registered or not, and checks the redirect only after sign-in. `entra/setup.sh` now registers the URI; a fresh `setup.sh` run with that change hasn't been done. Nothing else was re-tested on 2026-10-24.

### Minted token

- RS256, header `kid` = the Key Vault key version, verified offline against the broker's JWKS. Payload as in the Portkey doc's examples: `portkey_oid`, `portkey_workspace`, `sub`, `email_id` (users only), `scope`, `exp` (default 3600 s), `defaults.config_slug`, `defaults.config_id`, `defaults.metadata` (here `team`, `entra_role`, `caller_kind`), and `usage_limits` when the policy sets it.
- Broker responses: no bearer 401 `missing_bearer_token`, garbage token 401 `invalid_token`, `GET` on the exchange path 405.

### Gateway

| Case | Result |
|---|---|
| Finance token (app or user), `config_slug` of config `b` | 200, answered by `config.targets[1]` |
| HR token, `config_slug` of config `c` | 200, answered by `config.targets[2]` |
| Payload tampered | 401 `JWT verification failed: signature verification failed. Error Code: 03` |
| Signature tampered | same text |
| Unknown `kid` | 401 `No matching key found for kid: <kid>. Error Code: 03` |
| No token | 401 `Invalid API Key. Error Code: 03` |
| Raw Entra token, Entra's JWKS not in the org setting | 401 `No matching key found for kid. Error Code: 03` |

- The hybrid gateway reads `defaults.config_slug` and ignores `defaults.config_id`. Put the slug in the policy. The SaaS gateway is reported (2026-10-24, not tested here) to read `defaults.config_id` instead. The broker sends both: `config_id` is the policy's optional `config_id`, or the slug when that's not set. Whether SaaS accepts the slug there is untested; if it doesn't, set `config_id` in the policy.
- The org's JWKS URL setting accepts a comma-separated list, as the doc says. Adding the broker's URL after an existing one worked with no sync lag: the first request after saving was accepted.
- A user token (one with `email_id`) for a workspace the user isn't a member of gets 403 `Error Code: 033` by default. App tokens skip that check. Setting `JWT_JIT_USER_ACCESS=ON` on the gateway admits the user token as a workspace service key, and all user cases then returned 200. That trades per-user attribution for availability; whether the logs still show the user wasn't checked. Per the doc, the request is then served under the workspace's service-level limits and policies, and any `x-portkey-workspace` header hint is discarded. Whether a `usage_limits` claim in the token still applies to such a request wasn't tested. The setting is documented under [Workspace resolution](https://portkey.ai/docs/product/enterprise-offering/org-management/jwt#workspace-resolution).
- `scope` carries gateway scope names; use the ones in the Portkey doc (the logs scopes are `logs.read`, `logs.write`, `logs.export`). The test policy's `logs.view` isn't one of them and the gateway accepted the token anyway; what an unknown scope grants wasn't tested.
- Requests carried no `x-portkey-config` header, so the token's config decided. The doc says a config ID sent in a header can override the JWT default; that wasn't tested, so don't rely on `defaults` as a lock.

### Not tested

- Key rotation (a second key version in the JWKS) and JWKS cache lag.
- SaaS gateway.
- Mode B with Entra's own JWKS configured on the org (hybrid only: the SaaS gateway is reported to take Mode A only).
- `usage_limits` (array shape in the doc) and its enforcement. The Portkey doc says each unique JWT is tracked separately for token-level limits, so a budget in the claim may restart whenever a client gets a fresh token from the broker; not checked. Use workspace policies for budgets that must survive a token refresh.
- Per-user attribution in Portkey logs under `JWT_JIT_USER_ACCESS=ON`.

## License

MIT; see [LICENSE](LICENSE).

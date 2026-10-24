# AGENTS.md

Guidance for coding agents running or changing this repo. Read README.md first.

## What running this touches

- **Entra** (`entra/setup.sh`): app registrations and service principals, groups, test users and app role assignments, all named with a prefix. Secrets and test-user passwords go to `entra/.state.env` (mode 600, gitignored).
- **Gateway objects** (`gateway/setup.sh`, airs-cli): configs `a`, `b`, `c` per role in two existing workspaces, and it changes each workspace's default config (`defaults.user_api_key_config`). The original defaults are saved in `gateway/.state.env` (gitignored) for the teardown. This edits shared workspaces: get the operator's go-ahead first.
- **Org JWT setting**: the broker's JWKS URL added to the org's JWKS URL list in Admin Settings. This is a manual step and affects every user of the org's JWT auth.
- **Gateway env** (not done by this repo): `JWT_ENABLED=ON`, and optionally `JWT_JIT_USER_ACCESS=ON`, a Helm or env change on a shared gateway that needs the operator's go-ahead.
- **Azure** (`infra/deploy.sh`): resource group (or an existing one), Key Vault with an RSA-2048 signing key, managed identity, Container Apps environment and a Container App with a public HTTPS endpoint. The endpoint serves the JWKS publicly by design and exchanges only valid Entra tokens. Terraform state stays local (gitignored); `infra/terraform.tfvars`, `policy.auto.tfvars` and `image.auto.tfvars` are gitignored.
- **Container registry** (`broker/publish.sh`): pushes a public image to GHCR from an ssh build host, using a short-lived token piped over ssh.
- **Test runs** (`repro/run.sh`) send requests only. Results in `repro/results/` (gitignored) contain decoded claims, not tokens.

## Rules

- **Secrets.** Never print, log or commit tokens, API keys, client secrets or JWTs. When inspecting JSON from a CLI
  or API that may carry secrets, select known-safe fields (`jq '{id, name}'`, or `jq 'keys'` first); don't rely on
  deleting the field names you expect.
- **Tenant data stays out of git.** Keep deployment facts in gitignored files. Don't add tenant or account IDs, URLs
  of your deployment, real IPs or customer names to tracked files; use placeholders (`<gateway>`, `<workspace uuid>`).
- **Only touch what you created.** Never delete objects you didn't create; others may share the tenant.
- **Report what you observe.** A result counts only if a log or response shows it. If a claim comes from docs or code
  reading rather than a run, say so.
- **Gateway-side changes and teardown need the operator's word.** Don't change org settings, gateway env or workspace defaults, and don't destroy anything, on your own initiative.

## Cleanup (always finish with this)

1. `terraform destroy` in `infra/` (it purges the soft-deleted Key Vault and key).
2. `gateway/teardown.sh`: removes the configs it created and restores the workspace defaults from `gateway/.state.env` (the restore is unverified; check the defaults afterwards).
3. `entra/teardown.sh`: removes the prefixed apps, groups and users.
4. Remove the broker's JWKS URL from the org setting (manual), and revert `JWT_JIT_USER_ACCESS` if you set it only for this test.
5. List by prefix in Azure, Entra and the gateway to confirm nothing is left.

## Changing the code

- Broker: TypeScript on Node 20 (`tsc` build), dependencies `jose` and the Azure SDK only. `cd broker && npm ci && npm test` runs the unit tests offline.
- The image tag is a hash of `broker/src`, `package*.json`, `tsconfig.json` and `Dockerfile`; any change needs a `broker/publish.sh` run and `infra/deploy.sh <new image>`.
- The policy shape lives in `infra/variables.tf` (`policy`) and `broker/src/policy.ts`; change both together. `gateway/setup.sh` writes the policy file that `infra/` consumes.
- `repro/run.sh` expectations (config option indexes, error texts) mirror the README Findings; update both together.

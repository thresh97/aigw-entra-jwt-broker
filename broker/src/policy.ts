export interface RolePolicy {
  workspace: string;
  // Hybrid gateways read defaults.config_slug and ignore defaults.config_id; SaaS honors config_id. Both are emitted.
  config_slug: string;
  config_id?: string;
  scopes: string[];
  metadata?: Record<string, string>;
  // Passed through unchanged so the repro can try the array shape from the Portkey docs and other shapes.
  usage_limits?: unknown;
}

// Object key order is the precedence order when a caller holds several roles.
export type Policy = Record<string, RolePolicy>;

export interface Resolved {
  role: string;
  policy: RolePolicy;
}

export function parsePolicy(json: string): Policy {
  const parsed = JSON.parse(json) as Policy;
  for (const [role, p] of Object.entries(parsed)) {
    if (!p.workspace || !p.config_slug || !Array.isArray(p.scopes) || p.scopes.length === 0) {
      throw new Error(`policy for role ${role} needs workspace, config_slug and a non-empty scopes array`);
    }
  }
  return parsed;
}

// Returns null when the caller holds none of the roles in the policy: the caller must be refused.
export function resolvePolicy(policy: Policy, roles: string[]): Resolved | null {
  for (const role of Object.keys(policy)) {
    if (roles.includes(role)) return { role, policy: policy[role] };
  }
  return null;
}

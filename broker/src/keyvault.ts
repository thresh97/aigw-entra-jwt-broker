import { createHash } from "node:crypto";
import { DefaultAzureCredential, TokenCredential } from "@azure/identity";
import { CryptographyClient, KeyClient } from "@azure/keyvault-keys";
import type { Signer } from "./broker";

export interface PublicJwk {
  kty: "RSA";
  n: string;
  e: string;
  kid: string;
  alg: "RS256";
  use: "sig";
}

interface Loaded {
  at: number;
  jwks: { keys: PublicJwk[] };
  newest: Signer;
}

const CACHE_MS = 5 * 60 * 1000;

// kid is the Key Vault key version, so a rotated key gets a new kid and old tokens stay verifiable
// as long as the old version is still enabled.
export class KeyVaultKeys {
  private keyClient: KeyClient;
  private credential: TokenCredential;
  private loaded?: Loaded;

  constructor(vaultUrl: string, private keyName: string, credential?: TokenCredential) {
    this.credential = credential ?? new DefaultAzureCredential();
    this.keyClient = new KeyClient(vaultUrl, this.credential);
  }

  private async load(): Promise<Loaded> {
    if (this.loaded && Date.now() - this.loaded.at < CACHE_MS) return this.loaded;

    const versions = [];
    for await (const props of this.keyClient.listPropertiesOfKeyVersions(this.keyName)) {
      if (props.enabled !== false && props.version) versions.push(props);
    }
    versions.sort((a, b) => (b.createdOn?.getTime() ?? 0) - (a.createdOn?.getTime() ?? 0));
    if (versions.length === 0) throw new Error(`no enabled versions of key ${this.keyName}`);

    const keys: PublicJwk[] = [];
    let newest: Signer | undefined;
    for (const props of versions) {
      const key = await this.keyClient.getKey(this.keyName, { version: props.version });
      const { n, e } = key.key ?? {};
      if (!n || !e || !key.id) continue;
      const kid = props.version!;
      keys.push({
        kty: "RSA",
        n: Buffer.from(n).toString("base64url"),
        e: Buffer.from(e).toString("base64url"),
        kid,
        alg: "RS256",
        use: "sig",
      });
      if (!newest) {
        const crypto = new CryptographyClient(key.id, this.credential);
        newest = {
          keyId: kid,
          // Key Vault signs a digest, not the message: hash first.
          sign: async (input) => {
            const digest = createHash("sha256").update(input).digest();
            const result = await crypto.sign("RS256", digest);
            return Buffer.from(result.result);
          },
        };
      }
    }
    if (!newest) throw new Error(`key ${this.keyName} has no usable RSA public key`);

    this.loaded = { at: Date.now(), jwks: { keys }, newest };
    return this.loaded;
  }

  async jwks() {
    return (await this.load()).jwks;
  }

  async signer(): Promise<Signer> {
    return (await this.load()).newest;
  }
}

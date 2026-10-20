// The station's key: <data>/mesh/secret.key, 32 raw bytes (an Ed25519 seed, as iroh's SecretKey keeps it), made on
// first use. Its public half is the station's id; it signs what the station says to still.fail cloud.
import { createHash, createPrivateKey, createPublicKey, randomBytes, sign as edSign, type KeyObject } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { writePrivate } from "../ops/files.ts";
import { meshDir } from "./state.ts";

// PKCS#8 for an Ed25519 seed: this header, then the 32 bytes.
const PKCS8_ED25519 = Buffer.from("302e020100300506032b657004220420", "hex");

export class StationKey {
  readonly seed: Buffer;
  readonly private: KeyObject;
  /// The station's id: its public key, hex.
  readonly id: string;

  constructor(seed: Buffer) {
    if (seed.length !== 32) throw new Error("the station's key is not 32 bytes");
    this.seed = seed;
    this.private = createPrivateKey({ key: Buffer.concat([PKCS8_ED25519, seed]), format: "der", type: "pkcs8" });
    const jwk = createPublicKey(this.private).export({ format: "jwk" });
    this.id = Buffer.from(jwk.x as string, "base64url").toString("hex");
  }

  /// Signed, hex (as `hex::encode(key.sign(…).to_bytes())`).
  sign(message: string): string {
    return edSign(null, Buffer.from(message), this.private).toString("hex");
  }
}

export function loadKey(data: string): StationKey {
  const path = join(meshDir(data), "secret.key");
  if (existsSync(path)) return new StationKey(readFileSync(path));
  const seed = randomBytes(32);
  writePrivate(path, seed);
  return new StationKey(seed);
}

export const sha256hex = (bytes: Uint8Array | string) => createHash("sha256").update(bytes).digest("hex");

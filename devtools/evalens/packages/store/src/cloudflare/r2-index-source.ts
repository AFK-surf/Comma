import { canonicalJson } from "@evalens/core/store/digest";
import type { ReindexObjectSource } from "../metadata/index-service";

export class R2IndexSource implements ReindexObjectSource {
  constructor(private readonly bucket: R2Bucket) {}

  async *list(prefix: string): AsyncIterable<string> {
    const directoryPrefix = prefix.endsWith("/") ? prefix : `${prefix}/`;
    let cursor: string | undefined;
    do {
      const result = await this.bucket.list({ prefix: directoryPrefix, cursor });
      for (const object of result.objects) yield object.key;
      cursor = result.truncated ? result.cursor : undefined;
    } while (cursor);
  }

  async readJson(key: string): Promise<unknown> {
    const object = await this.bucket.get(key);
    if (!object) throw new Error(`object does not exist: ${key}`);
    return object.json();
  }

  async exists(key: string): Promise<boolean> {
    return (await this.bucket.head(key)) !== null;
  }

  async delete(key: string): Promise<void> {
    await this.bucket.delete(key);
  }
}

export async function digestJson(value: unknown): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonicalJson(value))
  );
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

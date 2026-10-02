import { open } from "node:fs/promises";

/** Intent and receipt records contain bounded metadata, never Host files or secrets. */
export async function readIntentFile(path: string): Promise<string> {
  const file = await open(path, "r");
  try {
    const bytes = Buffer.alloc(16 * 1024 + 1);
    const { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
    if (bytesRead === bytes.length)
      throw new Error("Saved compute record exceeds its metadata limit.");
    return bytes.subarray(0, bytesRead).toString("utf8");
  } finally {
    await file.close();
  }
}

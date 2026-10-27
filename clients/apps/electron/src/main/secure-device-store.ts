import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { safeStorage } from "electron";
import { z } from "zod";

const recordSchema = z.object({
  deviceId: z.string().min(1).max(160),
  connectorToken: z.string().min(1).max(4096),
  voiceKeyId: z.string().min(1).max(160),
  name: z.string().max(200),
  createdAt: z.number(),
  confirmed: z.boolean(),
  revoking: z.boolean().optional(),
});
/** Each encrypted record has an indexed pending flag. Reads never scan all paired devices. */
export class SecureDeviceStore {
  private readonly db: DatabaseSync;
  private readonly cursors = new Map<string, string>();
  constructor(path: string) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec(
      "CREATE TABLE IF NOT EXISTS paired(scope TEXT NOT NULL, id TEXT NOT NULL, pending INTEGER NOT NULL, value BLOB NOT NULL, PRIMARY KEY(scope,id)); CREATE INDEX IF NOT EXISTS paired_pending ON paired(scope,pending,id)"
    );
  }
  call(op: string, input: Record<string, unknown>): unknown {
    if (!safeStorage.isEncryptionAvailable())
      throw new Error("Secure storage is unavailable");
    const scope = JSON.stringify([input.audience, input.account, input.workspace]);
    if (op === "put") {
      const record = recordSchema.parse(input.record);
      const value = safeStorage.encryptString(JSON.stringify(record));
      this.db
        .prepare(
          "INSERT INTO paired(scope,id,pending,value) VALUES(?,?,?,?) ON CONFLICT(scope,id) DO UPDATE SET pending=excluded.pending,value=excluded.value"
        )
        .run(scope, record.deviceId, record.confirmed ? 0 : 1, value);
      return null;
    }
    const device = typeof input.deviceId === "string" ? input.deviceId : "";
    if (op === "remove") {
      this.db.prepare("DELETE FROM paired WHERE scope=? AND id=?").run(scope, device);
      return null;
    }
    if (op !== "records") throw new Error("Unknown secure device operation");
    const rows = device
      ? this.db
          .prepare("SELECT id,value FROM paired WHERE scope=? AND id=?")
          .all(scope, device)
      : this.db
          .prepare(
            "SELECT id,value FROM paired WHERE scope=? AND pending=1 AND id>? ORDER BY id LIMIT 20"
          )
          .all(scope, this.cursors.get(scope) ?? "");
    if (!device)
      this.cursors.set(scope, rows.length === 20 ? String(rows.at(-1)!.id) : "");
    return rows.map((row) =>
      recordSchema.parse(
        JSON.parse(safeStorage.decryptString(Buffer.from(row.value as Uint8Array)))
      )
    );
  }
  close(): void {
    this.db.close();
  }
}

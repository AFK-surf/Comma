import { afterEach, expect, it, vi } from "vitest";
import { createCipheriv, createDecipheriv } from "node:crypto";
const state = vi.hoisted(() => ({ available: true }));
vi.mock("electron", () => ({
  safeStorage: {
    isEncryptionAvailable: () => state.available,
    encryptString: (s: string) => {
      const c = createCipheriv("aes-256-cbc", Buffer.alloc(32, 1), Buffer.alloc(16, 2));
      return Buffer.concat([c.update(s), c.final()]);
    },
    decryptString: (b: Buffer) => {
      const c = createDecipheriv(
        "aes-256-cbc",
        Buffer.alloc(32, 1),
        Buffer.alloc(16, 2)
      );
      return Buffer.concat([c.update(b), c.final()]).toString();
    },
  },
}));
import { SecureDeviceStore } from "../secure-device-store";
afterEach(() => {
  state.available = true;
});
it("isolates encrypted device records by account and pages pending records", () => {
  const store = new SecureDeviceStore(":memory:");
  const scope = { audience: "https://api.test", account: "one", workspace: "wsp" };
  for (let i = 0; i < 23; i++)
    store.call("put", {
      ...scope,
      record: {
        deviceId: `device-${String(i).padStart(2, "0")}`,
        connectorToken: "salix_conn_secret",
        voiceKeyId: "key",
        name: "Board",
        createdAt: 1,
        confirmed: false,
      },
    });
  expect(store.call("records", { ...scope, account: "two", pending: true })).toEqual(
    []
  );
  expect(store.call("records", { ...scope, pending: true })).toHaveLength(20);
  expect(store.call("records", { ...scope, pending: true })).toHaveLength(3);
  store.call("remove", { ...scope, deviceId: "device-00" });
  expect(store.call("records", { ...scope, deviceId: "device-00" })).toEqual([]);
  state.available = false;
  expect(() => store.call("records", scope)).toThrow("unavailable");
  store.close();
});
it("keeps the revoking flag, so the core retries revocation instead of confirming", () => {
  const store = new SecureDeviceStore(":memory:");
  const scope = { audience: "https://api.test", account: "one", workspace: "wsp" };
  store.call("put", {
    ...scope,
    record: {
      deviceId: "device",
      connectorToken: "salix_conn_secret",
      voiceKeyId: "key",
      name: "device",
      createdAt: 0,
      confirmed: false,
      revoking: true,
    },
  });
  expect(store.call("records", { ...scope, pending: true })).toMatchObject([
    { deviceId: "device", revoking: true },
  ]);
  store.close();
});

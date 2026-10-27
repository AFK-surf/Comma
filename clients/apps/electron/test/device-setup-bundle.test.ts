import { createRequire } from "node:module";
import { resolve } from "node:path";
import { compileFunction } from "node:vm";
import { build } from "vite";
import { expect, it, vi } from "vitest";
import { sessionProductLease } from "@comma/session-contract";
import { MainCredentialGate } from "../src/main/modules/session/main-credential-gate";
import { acceptVerified } from "../src/test-support/session-gate";
import type { DeviceSetupHost } from "../src/main/modules/device-setup";

it("starts device setup through the CommonJS Main bundle's native loader", async () => {
  // Exercise Vite's output: source-module tests leave import.meta.url intact.
  const result = await build({
    configFile: false,
    logLevel: "silent",
    build: {
      write: false,
      minify: false,
      lib: {
        entry: resolve("apps/electron/src/main/modules/device-setup/index.ts"),
        formats: ["cjs"],
        fileName: () => "device-setup.cjs",
      },
      rolldownOptions: { external: ["electron", /^node:/] },
    },
  });
  const bundle = Array.isArray(result) ? result[0]! : result;
  if (!("output" in bundle)) throw new Error("Expected a completed build");
  const chunk = bundle.output.find((item) => item.type === "chunk" && item.isEntry);
  if (chunk?.type !== "chunk") throw new Error("No device setup bundle");
  const appPath = resolve("apps/electron");
  const binaryPath = resolve(appPath, "dist/native/macos/comma-device-bluetooth.node");
  const nativeCall = vi.fn(async () => "null");
  const require = createRequire(resolve(appPath, "test/device-setup-bundle.test.ts"));
  const runtimeRequire = (id: string): unknown => {
    if (id === "electron")
      return { app: { isPackaged: false, getAppPath: () => appPath } };
    if (id === "node:module")
      return {
        createRequire: (filename: string) => {
          // Use Node's real validation and resolution; only the radio is scripted.
          const load = createRequire(filename);
          return (path: string) =>
            path === binaryPath ? { call: nativeCall } : load(path);
        },
      };
    return require(id);
  };
  const module = { exports: {} as { DeviceSetupHost: typeof DeviceSetupHost } };
  compileFunction(chunk.code, ["module", "exports", "require", "process"])(
    module,
    module.exports,
    runtimeRequire,
    process
  );
  const gate = new MainCredentialGate({
    authorityInstanceId: "device-test-main",
    trustedAudience: "https://api.test",
  });
  const snapshot = acceptVerified(gate, {
    audience: "https://api.test",
    email: "device@example.com",
    expiresAtEpochSeconds: 1_900_000_000,
    sessionId: "device-session",
    token: "main-only-token",
    userId: "device-user",
  });
  const host = new module.exports.DeviceSetupHost(appPath, {
    acquireProductCredential: gate.acquireProductCredential.bind(gate),
  });
  const lease = sessionProductLease(snapshot)!;
  const input = { session: "scan", lease };
  await expect(host.call("start", input)).resolves.toBeNull();
  expect(nativeCall).toHaveBeenCalledWith("start", JSON.stringify(input));
  await expect(
    host.call("start", {
      ...input,
      lease: { ...lease, generation: lease.generation - 1 },
    })
  ).rejects.toThrow("Device setup session changed");
  expect(nativeCall).toHaveBeenCalledTimes(1);
  host.close();
  expect(nativeCall).toHaveBeenLastCalledWith("close", JSON.stringify(input));
});

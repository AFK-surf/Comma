import { app } from "electron";
import { createRequire } from "node:module";
import { join } from "node:path";
import type { SessionProductLease } from "@comma/session-contract";
import type { MainSessionHost } from "../session/session-host";
import { SecureDeviceStore } from "../../secure-device-store";

type Addon = { call(op: string, input: string): Promise<string> };
/** The core utility process is the only caller. No credential or GATT value enters a renderer. */
export class DeviceSetupHost {
  private addon: Addon | null = null;
  private store: SecureDeviceStore | null = null;
  private active: Record<string, unknown> | null = null;
  constructor(
    private readonly directory: string,
    private readonly session: Pick<MainSessionHost, "acquireProductCredential">
  ) {}
  async call(op: string, input: Record<string, unknown>): Promise<unknown> {
    if (op === "put" || op === "remove" || op === "records") {
      // Late mint results may still need a revocation record after sign-out.
      this.store ??= new SecureDeviceStore(
        join(this.directory, "paired-devices.sqlite")
      );
      return this.store.call(op, input);
    }
    if (op !== "disconnect" && op !== "close" && op !== "stopScan") {
      const expected = input.lease as SessionProductLease;
      const lease = this.session.acquireProductCredential({
        authorityInstanceId: expected.authorityInstanceId,
        generation: expected.generation,
        expectedAudience: expected.audience,
        expectedSessionId: expected.sessionId,
      });
      if (!lease) throw new Error("Device setup session changed");
    }
    // Main is bundled as CommonJS, where Vite replaces import.meta with {}.
    // Resolve the native addon from the app using an absolute loader filename.
    this.addon ??= createRequire(join(app.getAppPath(), "device-bluetooth-loader.cjs"))(
      app.isPackaged
        ? join(process.resourcesPath, "native/macos/comma-device-bluetooth.node")
        : join(app.getAppPath(), "dist/native/macos/comma-device-bluetooth.node")
    ) as Addon;
    if (op === "start") this.active = input;
    return JSON.parse(await this.addon.call(op, JSON.stringify(input))) as unknown;
  }
  close(): void {
    if (this.addon && this.active)
      void this.addon.call("close", JSON.stringify(this.active)).catch(() => {});
    this.active = null;
  }
}

import { _electron as electron, expect, test } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

// S4: main brokers a direct MessagePort between two windows; the business surface
// is an AsyncCall<PeerApi> proxy (frames bypass main after the handshake). This
// verifies the renderer flow end to end: window A opens a second window B (S3), B
// exposes a localApi via peers.onConnection, A connects via peers.connect and
// calls conn.remote (RPC round-trip), then closing B fires A's onClose
// (disconnect, no auto-reconnect). Mutations that turn it red: break the brokered
// port delivery (RPC never resolves) or the window-close disconnect notification
// (onClose never fires).
type PeerConnection = {
  remote: { echo: (value: string) => Promise<string> };
  onClose: (listener: () => void) => void;
};
type PeerWindow = Window & {
  commaNative: {
    windows: {
      close: (input: { windowId: string }) => Promise<unknown>;
      create: (input: { route: string }) => Promise<unknown>;
    };
    peers: {
      connect: (opts: {
        target: { windowId: string };
        localApi?: Record<string, unknown>;
      }) => Promise<PeerConnection>;
      onConnection: (
        listener: (connection: PeerConnection) => void,
        opts?: { localApi?: Record<string, unknown> }
      ) => void;
    };
  };
  commaPeerResult?: string;
  commaPeerClosed?: boolean;
};

test.describe("renderer peer channel", () => {
  let userDataDir: string;

  test.beforeEach(async () => {
    userDataDir = await mkdtemp(join(tmpdir(), "comma-peer-channel-e2e-"));
  });

  test.afterEach(async () => {
    await rm(userDataDir, { force: true, recursive: true });
  });

  test("two windows establish a peer channel: RPC round-trip + disconnect on close", async () => {
    const app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: { ...process.env, NODE_ENV: "test" },
    });
    try {
      const windowA = await findElectronWindowByNativeRole(app, "main-window");
      await windowA.waitForLoadState("domcontentloaded");

      // A opens a second product window B (S3).
      const [windowB] = await Promise.all([
        app.waitForEvent("window"),
        windowA.evaluate(() =>
          (window as unknown as PeerWindow).commaNative.windows.create({
            route: "/",
          })
        ),
      ]);
      await windowB.waitForLoadState("domcontentloaded");

      // B exposes a localApi and registers the incoming connection BEFORE A
      // connects, so the broker has a listener to hand the port to.
      await windowB.evaluate(() => {
        (window as unknown as PeerWindow).commaNative.peers.onConnection(() => {}, {
          localApi: { echo: (value: string) => `echo:${value}` },
        });
      });

      // A connects to B, does an RPC round-trip against B's localApi, and records
      // disconnect via onClose.
      await windowA.evaluate(async () => {
        const w = window as unknown as PeerWindow;
        const connection = await w.commaNative.peers.connect({
          target: { windowId: "win_dynamic_1" },
          localApi: {},
        });
        w.commaPeerResult = await connection.remote.echo("hi");
        connection.onClose(() => {
          w.commaPeerClosed = true;
        });
      });

      // The RPC round-trip resolved against B's localApi (frames bypass main).
      expect(
        await windowA.evaluate(() => (window as unknown as PeerWindow).commaPeerResult)
      ).toBe("echo:hi");

      // Close B through the real generated window command. Playwright Page.close
      // only tears down a renderer target and is not the product BrowserWindow
      // lifecycle this scenario is intended to prove.
      await windowA.evaluate(() =>
        (window as unknown as PeerWindow).commaNative.windows.close({
          windowId: "win_dynamic_1",
        })
      );
      await expect.poll(() => windowB.isClosed()).toBe(true);
      await expect
        .poll(() =>
          windowA.evaluate(
            () => (window as unknown as PeerWindow).commaPeerClosed === true
          )
        )
        .toBe(true);
    } finally {
      await app.close();
    }
  });
});

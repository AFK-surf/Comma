import { expect, openedWindow, test } from "./electron-test";

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
  test(
    "two windows establish a peer channel: RPC round-trip + disconnect on close",
    { tag: "@shared-app" },
    async ({ sharedElectron: { app, mainWindow: windowA } }) => {
      {
        // A opens a second product window B (S3).
        const windowB = await openedWindow(app, () =>
          windowA.evaluate(() =>
            (window as unknown as PeerWindow).commaNative.windows.create({
              route: "/",
            })
          )
        );

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
          await windowA.evaluate(
            () => (window as unknown as PeerWindow).commaPeerResult
          )
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
      }
    }
  );
});

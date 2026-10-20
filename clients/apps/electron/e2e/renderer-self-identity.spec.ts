import { expect, test } from "./electron-test";

// S2: the main process injects each managed window's identity into argv
// (--window-id / --window-role) and the preload exposes a frozen read-only
// `commaNative.self` to the renderer. This proves the main window's identity is
// actually readable end to end — the injected values, not the unknown/web
// fallback. Dynamic-window differentiation is covered by the companion S3
// renderer-window-open scenario. Mutation that turns this red: drop the argv
// injection in window-options so the preload resolves the unknown fallback.
test.describe("renderer self identity", () => {
  test(
    "main window exposes its injected identity via commaNative.self",
    { tag: "@shared-app" },
    async ({ sharedElectron: { mainWindow } }) => {
      const identity = await mainWindow.evaluate(
        () =>
          (window as unknown as { commaNative?: { self?: unknown } }).commaNative?.self
      );
      expect(identity).toEqual({ role: "main-window", windowId: "win_main" });
    }
  );
});

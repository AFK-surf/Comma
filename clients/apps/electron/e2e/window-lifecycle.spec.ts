import { expect, test } from "./electron-test";

// macOS can tell a window it was hidden after the window is gone, as the app
// quits. Electron's own listener then read the destroyed window and threw in
// Main ("Object has been destroyed"): the app ended with an uncaught exception.
test(
  "a window that is gone takes a late visibility event without a fault",
  { tag: "@shared-app" },
  async ({ sharedElectron }) => {
    const fault = await sharedElectron.app.evaluate(async ({ BrowserWindow }) => {
      const window = new BrowserWindow({ show: false });
      await new Promise<void>((closed) => {
        window.once("closed", () => closed());
        window.destroy();
      });
      try {
        for (const event of ["show", "hide", "minimize", "maximize", "restore"])
          window.emit(event);
        return null;
      } catch (error) {
        return String(error);
      }
    });
    expect(fault).toBeNull();
  }
);

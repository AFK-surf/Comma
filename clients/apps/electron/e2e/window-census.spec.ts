import { _electron as electron, expect, test } from "@playwright/test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { FEATURE_SURFACES } from "../src/main/feature-surfaces";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");

// The set of window surfaces that may exist is the FEATURE_SURFACES manifest. This
// census adds the runtime dimensions the manifest deliberately does not carry:
// route, platform presence, and initial visibility. The workbench is dev-only;
// Side Chat is a persistent production window on macOS but starts hidden. Its
// child surfaces are created on demand; non-macOS builds must not create the
// native-only surfaces. Keyed by manifest id so a surface added without a
// classification fails the drift check below.
type ProductionPresence = "all" | "darwin" | "never" | "on-demand" | "on-demand-darwin";
type ProductionVisibility = "hidden" | "visible";

const SURFACE_RUNTIME: Record<
  string,
  {
    productionPresence: ProductionPresence;
    productionVisibility?: ProductionVisibility;
    route: string;
  }
> = {
  "main-window": {
    productionPresence: "all",
    productionVisibility: "visible",
    route: "/",
  },
  "meeting-recorder-window": {
    productionPresence: "on-demand",
    route: "/meeting-recorder",
  },
  // Presented after sign-in until the account finishes the onboarding.
  "onboarding-window": {
    productionPresence: "on-demand",
    route: "/onboarding",
  },
  "site-permission-menu": {
    productionPresence: "on-demand",
    route: "/site-permission-menu",
  },
  "runtime-workbench": {
    productionPresence: "never",
    route: "/dev/workbench",
  },
  "side-chat": {
    productionPresence: "darwin",
    productionVisibility: "hidden",
    route: "/side-chat",
  },
  "side-chat-test-window": {
    productionPresence: "on-demand-darwin",
    route: "/side-chat/test-window",
  },
};

test.describe("electron production window census", () => {
  test("every FEATURE_SURFACES window is classified for the runtime census", () => {
    const declared = FEATURE_SURFACES.filter((s) => s.kind === "window")
      .map((s) => s.id)
      .toSorted();
    const classified = Object.keys(SURFACE_RUNTIME).toSorted();
    expect(classified).toEqual(declared);
  });

  let userDataDir: string;

  test.beforeEach(async () => {
    userDataDir = await mkdtemp(join(tmpdir(), "comma-window-census-e2e-"));
  });

  test.afterEach(async () => {
    await rm(userDataDir, { force: true, recursive: true });
  });

  test("built main opens exactly the production surfaces, never dev-only ones", async () => {
    const app = await electron.launch({
      args: [electronMain, `--user-data-dir=${userDataDir}`],
      cwd: electronAppDir,
      env: { ...process.env, NODE_ENV: "test" },
    });
    try {
      const mainWindow = await app.firstWindow();
      await mainWindow.waitForLoadState("domcontentloaded");
      // A dev-only surface, if the gate opened it, is created right after the main
      // window in the same ready handler. Give that a beat, then take the census.
      await mainWindow.waitForTimeout(2000);
      const windows = await app.evaluate(({ BrowserWindow }) =>
        BrowserWindow.getAllWindows().map((window) => {
          const url = window.webContents.getURL();
          return {
            route: new URL(url).hash.slice(1).split("?")[0] || "/",
            url,
            visibility: window.isVisible() ? "visible" : "hidden",
          };
        })
      );

      const productionSurfaces = FEATURE_SURFACES.flatMap((surface) => {
        const runtime = SURFACE_RUNTIME[surface.id];
        if (surface.kind !== "window" || !runtime) return [];
        const present =
          runtime.productionPresence === "all" ||
          (runtime.productionPresence === "darwin" && process.platform === "darwin");
        return present
          ? [
              {
                id: surface.id,
                route: runtime.route,
                visibility: runtime.productionVisibility,
              },
            ]
          : [];
      });
      const absentRoutes = FEATURE_SURFACES.flatMap((surface) => {
        const runtime = SURFACE_RUNTIME[surface.id];
        const isPresent = productionSurfaces.some(({ id }) => id === surface.id);
        return surface.kind === "window" && runtime && !isPresent
          ? [runtime.route]
          : [];
      });

      // Exactly the production surfaces for this platform exist, including the
      // persistent-but-hidden macOS Side Chat window. On-demand child surfaces
      // stay absent until a producer requests them.
      expect(windows).toHaveLength(productionSurfaces.length);
      for (const expectedSurface of productionSurfaces) {
        expect(
          windows.find(({ route }) => route === expectedSurface.route),
          expectedSurface.id
        ).toMatchObject({
          route: expectedSurface.route,
          visibility: expectedSurface.visibility,
        });
      }

      // Dev-only and platform-absent routes never leak into this production run.
      for (const route of absentRoutes) {
        expect(windows.some((window) => window.route === route)).toBe(false);
      }

      // Toasts render inside the app window now. The `/toast` surface was
      // removed from FEATURE_SURFACES, so it no longer has an absent-route
      // entry to cover it — assert directly that nothing resurrects it.
      expect(windows.some(({ route }) => route === "/toast")).toBe(false);
    } finally {
      await app.close();
    }
  });
});

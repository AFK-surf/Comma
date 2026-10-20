import { expect, test } from "./electron-test";
import { FEATURE_SURFACES } from "../src/main/feature-surfaces";

// The set of window surfaces that may exist is the FEATURE_SURFACES manifest. This
// census adds the runtime dimensions the manifest deliberately does not carry:
// route, presence, and initial visibility. The workbench is dev-only; the other
// accessory surfaces are created on demand. Keyed by manifest id so a surface
// added without a classification fails the drift check below.
type ProductionPresence = "all" | "never" | "on-demand";
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
};

test.describe("electron production window census", () => {
  test("every FEATURE_SURFACES window is classified for the runtime census", () => {
    const declared = FEATURE_SURFACES.filter((s) => s.kind === "window")
      .map((s) => s.id)
      .toSorted();
    const classified = Object.keys(SURFACE_RUNTIME).toSorted();
    expect(classified).toEqual(declared);
  });

  // The app as Main started it, at launch or after a reset: a dev-only surface, if the gate opened it, would be open
  // by the time Main's start finished, which the shared app waits for.
  test(
    "built main opens exactly the production surfaces, never dev-only ones",
    { tag: "@shared-app" },
    async ({ sharedElectron: { app } }) => {
      {
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
          return runtime.productionPresence === "all"
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

        // Exactly the production surfaces exist. On-demand surfaces stay absent
        // until a producer requests them.
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

        // Dev-only and on-demand routes never leak into this production run.
        for (const route of absentRoutes) {
          expect(windows.some((window) => window.route === route)).toBe(false);
        }

        // Toasts render inside the app window now. The `/toast` surface was
        // removed from FEATURE_SURFACES, so it no longer has an absent-route
        // entry to cover it — assert directly that nothing resurrects it.
        expect(windows.some(({ route }) => route === "/toast")).toBe(false);
      }
    }
  );
});

import { describe, expect, it } from "vitest";
import { findElectronWindowByRole } from "../../test-support/electron-window";

function createRolePage({
  label,
  matchingRoles,
  url,
}: {
  label: string;
  matchingRoles: string[];
  url: string;
}) {
  return {
    getByRole(role: string, options: { name?: string | RegExp } = {}) {
      const name = String(options.name ?? "");
      return {
        async count() {
          return matchingRoles.includes(`${role}:${name}`) ? 1 : 0;
        },
      };
    },
    label,
    async waitForLoadState() {},
    url: () => url,
  };
}

describe("findElectronWindowByRole", () => {
  it("skips the first dev-only window and returns the product shell window", async () => {
    const workbench = createRolePage({
      label: "workbench",
      matchingRoles: [],
      url: "assets://./index.html#/dev/workbench",
    });
    const productShell = createRolePage({
      label: "product",
      matchingRoles: ["complementary:App sidebar"],
      url: "assets://./index.html#/",
    });
    const app = {
      async firstWindow() {
        return workbench;
      },
      windows() {
        return [workbench, productShell];
      },
      async waitForEvent() {
        return productShell;
      },
    };

    await expect(
      findElectronWindowByRole(app, "complementary", {
        name: "App sidebar",
        timeoutMs: 50,
      })
    ).resolves.toBe(productShell);
  });
});

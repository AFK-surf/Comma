import { expect, test, type Page } from "@playwright/test";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import { resolve } from "node:path";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";
import {
  createBuiltFixtureServer,
  type BuiltFixtureServer,
} from "../helpers/built-fixture";

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const fixtureRoot = resolve(currentDir, "fixtures/focus-ring");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/focus-ring-e2e"),
    configFile: false,
    define: {
      "process.env.NODE_ENV": JSON.stringify("test"),
    },
    plugins: [react(), tailwindcss({ optimize: false }), localGroupSelectors()],
    resolve: {
      alias: {
        "@comma/ui/styles.css": resolve(clientsRoot, "packages/ui/src/styles.css"),
        "@comma/ui": resolve(clientsRoot, "packages/ui/src/index.ts"),
      },
    },
    root: fixtureRoot,
    server: {
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Focus ring fixture server did not expose a TCP port.");
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

const outlineOf = (page: Page, testId: string) =>
  page.evaluate((id) => {
    const element = document.querySelector<HTMLElement>(`[data-testid="${id}"]`);
    if (!element) throw new Error(`Missing fixture element: ${id}`);
    element.focus();
    const styles = getComputedStyle(element);
    return {
      focusVisible: element.matches(":focus-visible"),
      style: styles.outlineStyle,
    };
  }, testId);

/**
 * Chromium paints its own focus ring whenever native :focus-visible matches,
 * and React Aria decides our rings from separate modality tracking. Where the
 * two disagree the UA ring is the only one painted, which is what the
 * stylesheet suppresses -- narrowly, because for everything React Aria does not
 * own that ring is the only focus indicator there is.
 */
test("suppresses the UA focus ring only where React Aria disowns the focus", async ({
  page,
}) => {
  await page.goto(fixtureUrl);
  await page.waitForFunction(() => Boolean(window.focusRingFixtureReady));

  // A real key press: Chromium withholds :focus-visible from programmatic
  // focus until the page has seen keyboard input.
  await page.keyboard.press("Tab");
  await expect(page.getByTestId("seed")).toBeFocused();

  const racPointer = await outlineOf(page, "rac-pointer");
  expect(racPointer.focusVisible).toBe(true);
  expect(racPointer.style).toBe("none");

  // React Aria called this one keyboard-driven, so its own ring applies and the
  // reset must stand aside.
  const racKeyboard = await outlineOf(page, "rac-keyboard");
  expect(racKeyboard.focusVisible).toBe(true);
  expect(racKeyboard.style).not.toBe("none");

  // Neither of these is React Aria's, and neither carries an author ring, so
  // the UA ring is their only focus indicator.
  for (const testId of ["plain", "link"]) {
    const untouched = await outlineOf(page, testId);
    expect(untouched.focusVisible, testId).toBe(true);
    expect(untouched.style, testId).not.toBe("none");
  }
});

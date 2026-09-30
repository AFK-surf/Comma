import { expect, test } from "@playwright/test";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import localGroupSelectors from "../../vite/comma-tailwind";
import type { AddressInfo } from "node:net";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createBuiltFixtureServer,
  type BuiltFixtureServer,
} from "../helpers/built-fixture";

type ControlledAnimationFrame = {
  cancellations: () => number;
  flush: (elapsedMs: number) => void;
  queued: () => number;
  restore: () => void;
};

declare global {
  interface Window {
    commaControlledAnimationFrame: ControlledAnimationFrame;
  }
}

const currentDir = fileURLToPath(new URL(".", import.meta.url));
const clientsRoot = resolve(currentDir, "../..");
const fixtureRoot = resolve(currentDir, "fixtures/login");

let fixtureServer: BuiltFixtureServer | undefined;
let fixtureUrl = "";

test.beforeAll(async () => {
  fixtureServer = await createBuiltFixtureServer({
    cacheDir: resolve(clientsRoot, "node_modules/.vite/login-e2e"),
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
      hmr: false,
      host: "127.0.0.1",
      port: 0,
    },
  });

  const address = fixtureServer.httpServer?.address();
  if (!address || typeof address === "string") {
    throw new Error("Login fixture server did not expose a TCP port.");
  }

  fixtureUrl = `http://127.0.0.1:${(address as AddressInfo).port}/`;
});

test.afterAll(async () => {
  await fixtureServer?.close();
});

test("formatted OTP paste normalizes before the logical six-character cap", async ({
  context,
  page,
}) => {
  const origin = new URL(fixtureUrl).origin;
  await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin });
  await page.goto(fixtureUrl);

  const input = page.getByRole("textbox", { name: "Verification code" });
  await expect(input).toHaveAttribute("autocomplete", "one-time-code");
  await expect(input).not.toHaveAttribute("maxlength");

  await page.evaluate(() => navigator.clipboard.writeText("123-456"));
  await input.click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+V" : "Control+V");

  await expect(input).toHaveValue("123456");
  await expect(page.getByTestId("verification-value")).toHaveText("123456");
  await expect(page.getByTestId("completed-code")).toHaveText("123456");
});

test("OTP autofill-style replacement normalizes and completes in the browser", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const input = page.getByRole("textbox", { name: "Verification code" });
  await input.evaluate((element) => {
    const valueSetter = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      "value"
    )?.set;
    if (!valueSetter) throw new Error("HTML input value setter is unavailable.");

    valueSetter.call(element, "654 321");
    element.dispatchEvent(
      new InputEvent("input", {
        bubbles: true,
        data: "654 321",
        inputType: "insertReplacementText",
      })
    );
  });

  await expect(input).toHaveValue("654321");
  await expect(page.getByTestId("verification-value")).toHaveText("654321");
  await expect(page.getByTestId("completed-code")).toHaveText("654321");
});

test("OTP replacement pop clears when the value changes during its feedback window", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const input = page.getByRole("textbox", { name: "Verification code" });
  const cells = page.locator("[data-login-code-cell]");

  await input.evaluate(async (element) => {
    const valueSetter = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      "value"
    )?.set;
    if (!valueSetter) throw new Error("HTML input value setter is unavailable.");

    const replaceValue = (value: string) => {
      valueSetter.call(element, value);
      element.dispatchEvent(
        new InputEvent("input", {
          bubbles: true,
          data: value,
          inputType: "insertReplacementText",
        })
      );
    };
    const codeCells = Array.from(
      document.querySelectorAll<HTMLElement>("[data-login-code-cell]")
    );

    await new Promise<void>((complete, reject) => {
      const timeout = window.setTimeout(() => {
        observer.disconnect();
        reject(new Error("OTP cells did not enter their pop state."));
      }, 1_000);
      const interruptPop = () => {
        if (!codeCells.every((cell) => cell.dataset.pop === "true")) return;

        observer.disconnect();
        window.clearTimeout(timeout);
        // Interrupt in the mutation microtask that first exposes the pop state,
        // deterministically before its 120 ms feedback timer can expire.
        replaceValue("65432");
        complete();
      };
      const observer = new MutationObserver(interruptPop);
      observer.observe(document.body, {
        attributeFilter: ["data-pop"],
        attributes: true,
        subtree: true,
      });

      replaceValue("654 321");
      interruptPop();
    });
  });

  await expect(input).toHaveValue("65432");
  await page.waitForTimeout(200);
  await expect
    .poll(() =>
      cells.evaluateAll((elements) =>
        elements.map((element) => element.getAttribute("data-pop"))
      )
    )
    .toEqual(Array.from({ length: 6 }, () => "false"));
});

test("the app reduced-motion override keeps focused popping OTP cells untransformed", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.goto(fixtureUrl);
  await page.evaluate(() => {
    document.documentElement.setAttribute("data-comma-reduced-motion", "true");
  });

  expect(
    await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches)
  ).toBe(false);

  const input = page.getByRole("textbox", { name: "Verification code" });
  const firstCell = page.locator("[data-login-code-cell]").first();
  await input.focus();
  await input.evaluate((element) => {
    const inputElement = element as HTMLInputElement;
    inputElement.setSelectionRange(0, 0);
    inputElement.dispatchEvent(new Event("select", { bubbles: true }));
  });
  await expect(firstCell).toHaveAttribute("data-active", "true");
  const transformWhileFocused = await firstCell.evaluate(
    (element) => getComputedStyle(element).transform
  );

  const transformDuringPop = await input.evaluate(async (element) => {
    const inputElement = element as HTMLInputElement;
    const valueSetter = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype,
      "value"
    )?.set;
    if (!valueSetter) throw new Error("HTML input value setter is unavailable.");
    const cell = document.querySelector<HTMLElement>("[data-login-code-cell]");
    if (!cell) throw new Error("OTP cell is unavailable.");

    return new Promise<string>((complete, reject) => {
      const timeout = window.setTimeout(() => {
        observer.disconnect();
        reject(new Error("OTP cell did not enter its pop state."));
      }, 1_000);
      const readTransform = () => {
        if (cell.dataset.pop !== "true") return;

        observer.disconnect();
        window.clearTimeout(timeout);
        complete(getComputedStyle(cell).transform);
      };
      const observer = new MutationObserver(readTransform);
      observer.observe(cell, {
        attributeFilter: ["data-pop"],
        attributes: true,
      });

      valueSetter.call(inputElement, "1");
      inputElement.dispatchEvent(
        new InputEvent("input", {
          bubbles: true,
          data: "1",
          inputType: "insertReplacementText",
        })
      );
      readTransform();
    });
  });

  expect({ transformDuringPop, transformWhileFocused }).toEqual({
    transformDuringPop: "none",
    transformWhileFocused: "none",
  });
});

test("invalid verification error preserves staggered phases until retry", async ({
  page,
}) => {
  await page.addInitScript(() => {
    const originalCancelAnimationFrame = window.cancelAnimationFrame.bind(window);
    const originalRequestAnimationFrame = window.requestAnimationFrame.bind(window);
    const callbacks = new Map<
      number,
      { callback: FrameRequestCallback; scheduledAt: number }
    >();
    let cancellations = 0;
    let nextFrameId = 1;

    window.requestAnimationFrame = (callback) => {
      const frameId = nextFrameId++;
      callbacks.set(frameId, { callback, scheduledAt: performance.now() });
      return frameId;
    };
    window.cancelAnimationFrame = (frameId) => {
      cancellations += 1;
      callbacks.delete(frameId);
    };

    window.commaControlledAnimationFrame = {
      cancellations: () => cancellations,
      flush: (elapsedMs: number) => {
        const queued = Array.from(callbacks.values());
        callbacks.clear();
        for (const { callback, scheduledAt } of queued) {
          callback(scheduledAt + elapsedMs);
        }
      },
      queued: () => callbacks.size,
      restore: () => {
        callbacks.clear();
        window.cancelAnimationFrame = originalCancelAnimationFrame;
        window.requestAnimationFrame = originalRequestAnimationFrame;
      },
    };
  });

  const errorUrl = new URL(fixtureUrl);
  errorUrl.searchParams.set("error", "1");
  await page.goto(errorUrl.href);

  const shakeCells = page.locator("[data-login-code-shake]");
  await expect(page.getByRole("alert")).toHaveText(
    "Please enter a valid verification code"
  );
  await expect(shakeCells).toHaveCount(6);
  await expect
    .poll(() => page.evaluate(() => window.commaControlledAnimationFrame.queued()))
    .toBeGreaterThan(0);

  const result = await page.evaluate(async () => {
    const controller = window.commaControlledAnimationFrame;
    try {
      controller.flush(17);
      const cells = Array.from(
        document.querySelectorAll<HTMLElement>("[data-login-code-shake]")
      );
      const positions = cells.slice(0, 3).map((element) => {
        const match = element.style.transform.match(/translate3d\(([-0-9.]+)px/);
        return match ? Number(match[1]) : 0;
      });
      const cancellationsBeforeRetry = controller.cancellations();
      const retryButton = Array.from(document.querySelectorAll("button")).find(
        (button) => button.textContent?.trim() === "Try again"
      );
      if (!retryButton) {
        throw new Error("Try again button is unavailable.");
      }

      retryButton.click();
      await Promise.resolve();
      return {
        alertPresent: document.querySelector('[role="alert"]') !== null,
        cancellationsAfterRetry: controller.cancellations(),
        cancellationsBeforeRetry,
        positions,
        transformsAfterRetry: cells.map((element) => element.style.transform),
      };
    } finally {
      controller.restore();
    }
  });

  expect(result.positions[0]).toBeLessThan(result.positions[1]!);
  expect(result.positions[1]).toBeLessThan(result.positions[2]!);
  expect(result.positions[2]).toBeGreaterThan(0);
  expect(result.alertPresent).toBe(false);
  expect(result.cancellationsAfterRetry).toBeGreaterThan(
    result.cancellationsBeforeRetry
  );
  expect(result.transformsAfterRetry).toEqual(Array.from({ length: 6 }, () => ""));
});

test("clicking an OTP cell selects that cell's character, or a caret in an empty cell", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const input = page.getByRole("textbox", { name: "Verification code" });
  const cells = page.locator("[data-login-code-cell]");
  await input.fill("12345");

  const inputBox = await input.boundingBox();
  if (!inputBox) throw new Error("Verification input has no browser layout box.");

  for (let index = 0; index < 6; index += 1) {
    const cellBox = await cells.nth(index).boundingBox();
    if (!cellBox) throw new Error(`Verification cell ${index} has no layout box.`);

    await input.click({
      position: {
        x: cellBox.x + cellBox.width / 2 - inputBox.x,
        y: cellBox.y + cellBox.height / 2 - inputBox.y,
      },
    });

    await expect
      .poll(() =>
        input.evaluate((element) => ({
          end: (element as HTMLInputElement).selectionEnd,
          start: (element as HTMLInputElement).selectionStart,
        }))
      )
      .toEqual({ end: index < 5 ? index + 1 : index, start: index });
    await expect(cells.nth(index)).toHaveAttribute("data-active", "true");
    await expect(cells.nth(index).locator("[data-login-code-caret]")).toHaveCount(
      index < 5 ? 0 : 1
    );
  }
});

test("invalid printable input preserves a selected filled OTP cell", async ({
  page,
}) => {
  await page.goto(fixtureUrl);

  const input = page.getByRole("textbox", { name: "Verification code" });
  const cells = page.locator("[data-login-code-cell]");
  await input.fill("12345");

  const inputBox = await input.boundingBox();
  const cellBox = await cells.nth(2).boundingBox();
  if (!inputBox || !cellBox) {
    throw new Error("Verification input geometry is unavailable.");
  }

  await input.click({
    position: {
      x: cellBox.x + cellBox.width / 2 - inputBox.x,
      y: cellBox.y + cellBox.height / 2 - inputBox.y,
    },
  });
  await expect
    .poll(() =>
      input.evaluate((element) => ({
        end: (element as HTMLInputElement).selectionEnd,
        start: (element as HTMLInputElement).selectionStart,
      }))
    )
    .toEqual({ end: 3, start: 2 });

  await page.keyboard.type("-");

  await expect(input).toHaveValue("12345");
  await expect
    .poll(() =>
      input.evaluate((element) => ({
        end: (element as HTMLInputElement).selectionEnd,
        start: (element as HTMLInputElement).selectionStart,
      }))
    )
    .toEqual({ end: 3, start: 2 });

  await page.keyboard.type("9");

  await expect(input).toHaveValue("12945");
  await expect
    .poll(() =>
      input.evaluate((element) => ({
        end: (element as HTMLInputElement).selectionEnd,
        start: (element as HTMLInputElement).selectionStart,
      }))
    )
    .toEqual({ end: 4, start: 3 });
});

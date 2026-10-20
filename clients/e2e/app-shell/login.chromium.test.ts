import { expect, test, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";

useFixture(fixtureMount(new URL("./fixtures/login/src/main.tsx", import.meta.url)));
const fixtureUrl = "http://fixture.test/";

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

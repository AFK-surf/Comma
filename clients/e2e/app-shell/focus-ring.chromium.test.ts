import { expect, test, type Page, useFixture } from "./support/page";
import { fixtureMount } from "./support/fixture";

useFixture(
  fixtureMount(
    new URL("./fixtures/focus-ring/src/main.ts", import.meta.url),
    `<button data-testid="seed" type="button">Seed keyboard modality</button> <button data-rac data-testid="rac-pointer" type="button"> React Aria, pointer </button> <button data-focus-visible data-rac data-testid="rac-keyboard" type="button"> React Aria, keyboard </button> <button data-testid="plain" type="button">Plain button</button> <a class="markdown-stream-link" data-testid="link" href="#seed">Markdown link</a>`
  )
);
const fixtureUrl = "http://fixture.test/";

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

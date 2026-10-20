// The locators of a frame of another origin (../app-shell/support/frames.ts),
// run in an isolated world of the frame (CDP Page.createIsolatedWorld): it
// sees the frame's document, not its scripts. Resolves a locator's steps to
// elements as the page's locators do (../app-shell/support/page.ts), and only
// reads: what the test does to the frame is trusted input of the browser.
import {
  queryAllByLabelText,
  queryAllByRole,
  queryAllByText,
} from "@testing-library/dom";

export type TextMatch =
  | { text: string; exact?: boolean }
  | { pattern: string; flags: string };
export type FrameStep =
  | { css: string }
  | {
      role: string;
      name?: TextMatch;
      checked?: boolean;
      disabled?: boolean;
      level?: number;
      includeHidden?: boolean;
    }
  | { text: TextMatch }
  | { label: TextMatch }
  | { nth: number };

const normalize = (value: string) => value.replace(/\s+/g, " ").trim();
const matches = (actual: string, expected: TextMatch) =>
  "pattern" in expected
    ? new RegExp(expected.pattern, expected.flags).test(actual)
    : expected.exact
      ? normalize(actual) === normalize(expected.text)
      : normalize(actual)
          .toLowerCase()
          .includes(normalize(expected.text).toLowerCase());

const inOrder = <T extends Node>(elements: T[]) =>
  [...new Set(elements)].toSorted((a, b) =>
    a === b
      ? 0
      : a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING
        ? -1
        : 1
  );

function step(root: Element | Document, current: FrameStep): Element[] {
  if ("css" in current) {
    // Playwright's `:visible` at the end of a selector: only the elements that show.
    const visible = current.css.endsWith(":visible");
    const found = [
      ...root.querySelectorAll(visible ? current.css.slice(0, -8) : current.css),
    ];
    return visible
      ? found.filter((element) => {
          const rect = element.getBoundingClientRect();
          return (
            element.checkVisibility({ visibilityProperty: true }) &&
            rect.width > 0 &&
            rect.height > 0
          );
        })
      : found;
  }
  if ("role" in current) {
    const found = queryAllByRole(root as HTMLElement, current.role, {
      hidden: current.includeHidden ?? false,
      ...(current.checked === undefined ? {} : { checked: current.checked }),
      ...(current.level === undefined ? {} : { level: current.level }),
      ...(current.name === undefined
        ? {}
        : { name: (name: string) => matches(name, current.name!) }),
    });
    return current.disabled === undefined
      ? found
      : found.filter(
          (element) =>
            ((element as HTMLButtonElement).disabled ||
              element.getAttribute("aria-disabled") === "true") === current.disabled
        );
  }
  if ("text" in current)
    return queryAllByText(
      root as HTMLElement,
      (_content, element) =>
        Boolean(element) &&
        matches(element!.textContent ?? "", current.text) &&
        ![...element!.children].some((child) =>
          matches(child.textContent ?? "", current.text)
        ),
      { ignore: "script, style" }
    );
  if ("label" in current)
    return inOrder([
      ...queryAllByLabelText(
        root as HTMLElement,
        (content) => matches(content, current.label),
        {
          selector: "*",
        }
      ),
      ...[...root.querySelectorAll("[aria-label]")].filter((element) =>
        matches(element.getAttribute("aria-label") ?? "", current.label)
      ),
    ]);
  return [];
}

/** The elements `steps` locate in the frame's document, in document order. */
function all(steps: readonly FrameStep[]): Element[] {
  // From the document itself: a selector may name its root element (`html`).
  let found: (Element | Document)[] = [document];
  for (const current of steps) {
    if ("nth" in current) {
      const picked = current.nth < 0 ? found.at(current.nth) : found[current.nth];
      found = picked ? [picked] : [];
      continue;
    }
    found = inOrder(found.flatMap((root) => step(root, current)));
  }
  return found.filter((each): each is Element => each instanceof Element);
}

(globalThis as { commaFrameQuery?: unknown }).commaFrameQuery = { all };

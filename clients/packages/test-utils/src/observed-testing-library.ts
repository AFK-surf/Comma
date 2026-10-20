// @testing-library/react while records are written (DETERMINISM_RECORD,
// ./unit-record): the jsdom project aliases the package here
// (clients/vitest.config.ts). Its queries through `screen`, `within` and what
// `render` returns are observations (./assertion-record), so a test that
// asserts only by querying (`getBy*` throws when nothing matches) records what
// it found. Everything else is the package's own.
import { createRequire } from "node:module";
import * as library from "@testing-library/react/dist/index.js";
import { observedQueries } from "./assertion-record";

export * from "@testing-library/react/dist/index.js";

// testing-library's own accessible-name computation, from its dependency.
const fromReact = createRequire(
  createRequire(import.meta.url).resolve("@testing-library/react")
);
const { computeAccessibleName } = createRequire(
  fromReact.resolve("@testing-library/dom")
)("dom-accessibility-api") as {
  computeAccessibleName(
    element: Element,
    options?: { getComputedStyle?: typeof window.getComputedStyle }
  ): string;
};
// The window's own getComputedStyle, kept before any test spies on it: an
// observation must not show up as the test's own call.
const nativeGetComputedStyle = window.getComputedStyle.bind(window);
const accessibleName = (element: Element) =>
  computeAccessibleName(element, { getComputedStyle: nativeGetComputedStyle });

export const screen = observedQueries(library.screen, accessibleName);

// Both are overloaded: the observed forms take what they take.
type Loose = (...args: unknown[]) => object;

export const within = ((...args: unknown[]) =>
  observedQueries(
    (library.within as Loose)(...args),
    accessibleName
  )) as typeof library.within;

export const render = ((...args: unknown[]) =>
  observedQueries(
    (library.render as Loose)(...args),
    accessibleName
  )) as typeof library.render;

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { renderCardTokenDefaultsModule } from "../../../scripts/card-token-defaults-codegen.mjs";
import { cardCss } from "../cardStyles";
import { cardTokenDefaults } from "../cardTokenDefaults";
import { cardColorTokens, cardLengthTokens, cardRawTokens } from "../cardTypes";
import { dynamicUiDocument } from "../runtime";

const tokens = [...cardColorTokens, ...cardLengthTokens, ...cardRawTokens];
const defined = (rules: string) =>
  new Set([...rules.matchAll(/(--[a-z0-9-]+):/g)].map((match) => match[1]!));

describe("card token defaults", () => {
  it("are the design system's values for the tokens a host resolves", () => {
    const theme = readFileSync(
      resolve(import.meta.dirname, "../../../../ui/src/styles/theme.css"),
      "utf8"
    );
    expect(
      readFileSync(resolve(import.meta.dirname, "../cardTokenDefaults.ts"), "utf8")
    ).toBe(renderCardTokenDefaultsModule(theme, tokens));
  });

  it("give every token the widget's styles read a value, in both schemes", () => {
    // The phone apps resolve no tokens: without a value here a rule that reads
    // one is dropped, and a card shows with no surface, spacing or bars.
    const styles = `${dynamicUiDocument()}${cardCss}`;
    const read = new Set(
      [...styles.matchAll(/var\((--(?!wc-|comma-(?!icon))[a-z0-9-]+)/g)].map(
        (match) => match[1]!
      )
    );
    const [light, dark] = cardTokenDefaults.split(":root[data-comma-scheme=dark]");
    expect([...read].filter((name) => !defined(light!).has(name))).toEqual([]);
    // Every color that differs in the dark theme has its dark value.
    expect(defined(dark!).has("--color-bg-popup-secondary")).toBe(true);
    expect(defined(dark!).has("--shadow-sm")).toBe(true);
    for (const name of defined(dark!)) expect(defined(light!).has(name)).toBe(true);
  });
});

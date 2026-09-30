import { describe, expect, it } from "vitest";
import { selectorShape } from "../../scripts/catalog-shape.mjs";

const pluralMessage = (selectorInput: string, translation: string) => [
  {
    declarations: ["input count", `local countPlural = ${selectorInput}: plural`],
    selectors: ["countPlural"],
    match: {
      "countPlural=one": translation,
      "countPlural=other": translation,
    },
  },
];

describe("catalog selector shape", () => {
  it("ignores translated text while retaining selector declarations", () => {
    const source = pluralMessage("count", "{count} task");
    const translated = pluralMessage("count", "{count} 个任务");
    const wrongSelector = pluralMessage("total", "{count} 个任务");

    expect(selectorShape(translated)).toEqual(selectorShape(source));
    expect(selectorShape(wrongSelector)).not.toEqual(selectorShape(source));
  });
});

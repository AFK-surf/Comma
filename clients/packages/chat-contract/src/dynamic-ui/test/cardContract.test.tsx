import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { z } from "zod";
import { renderCardContract } from "../../../scripts/card-contract-codegen.mjs";
import { cardDataSchemas, cardFrame } from "../cardContract";
import {
  agendaFixture,
  barTrendFixture,
  breakTimerFixture,
  checklistFixture,
  comparisonFixture,
  compositionFixture,
  digestFixture,
  eventCountdownFixture,
  forecastFixture,
  goalFixture,
  groupedChecklistFixture,
  hotelOptionsFixture,
  itineraryFixture,
  metricFixture,
  metricGridFixture,
  newsFixture,
  placeFixture,
  planComparisonFixture,
  stagesFixture,
  storageFixture,
  timerFixture,
  trainOptionsFixture,
  trendFixture,
  versusFixture,
  watchlistFixture,
} from "../cardFixtures";
import type { CardKind } from "../cardTypes";
import { cardEngine } from "../cards";

type Data = Record<string, unknown>;

const fixtures: Array<[CardKind, object]> = [
  ["forecast", forecastFixture],
  ["options", trainOptionsFixture],
  ["options", hotelOptionsFixture],
  ["metric", metricFixture],
  ["metric", metricGridFixture],
  ["metric", goalFixture],
  ["trend", trendFixture],
  ["trend", barTrendFixture],
  ["trend", watchlistFixture],
  ["comparison", comparisonFixture],
  ["comparison", planComparisonFixture],
  ["comparison", versusFixture],
  ["schedule", agendaFixture],
  ["schedule", itineraryFixture],
  ["schedule", stagesFixture],
  ["checklist", checklistFixture],
  ["checklist", groupedChecklistFixture],
  ["composition", compositionFixture],
  ["composition", storageFixture],
  ["place", placeFixture],
  ["feed", newsFixture],
  ["feed", digestFixture],
  ["timer", timerFixture],
  ["timer", breakTimerFixture],
  ["timer", eventCountdownFixture],
];

function mount(kind: CardKind, data: unknown) {
  const target = document.createElement("section");
  document.body.append(target);
  const engine = cardEngine({
    seed: "block-1",
    locale: "en",
    copy: {},
    icons: {},
    state: {},
    send: () => {},
  });
  target.replaceChildren(engine.mount(target, { kind, data }, "card"));
  engine.dispose();
}

const unwrap = (schema: z.ZodType): z.ZodType =>
  schema instanceof z.ZodOptional ? unwrap(schema.unwrap() as z.ZodType) : schema;

/** The element schema of a list of objects, with the entries the list needs. */
function objectList(schema: z.ZodType) {
  const list = unwrap(schema);
  if (!(list instanceof z.ZodArray)) return undefined;
  const element = unwrap(list.element as z.ZodType);
  if (!(element instanceof z.ZodObject)) return undefined;
  const { minItems } = z.toJSONSchema(list) as { minItems?: number };
  return { element, needed: Math.max(minItems ?? 1, 1) };
}

/**
 * The data with one optional field left out of the first entry of a list,
 * once for every such field, nested lists included. Each list keeps only the
 * entries it needs, so a template that skips the entry empties the list.
 */
function withoutOptionalFields(schema: z.ZodObject, data: Data, path = "") {
  const variants: Array<{ path: string; data: Data }> = [];
  for (const [key, field] of Object.entries(schema.shape)) {
    const list = objectList(field as z.ZodType);
    const entries = data[key];
    if (!list || !Array.isArray(entries) || entries.length === 0) continue;
    const [first, ...rest] = entries as Data[];
    const replace = (entry: Data) => ({
      ...data,
      [key]: [entry, ...rest.slice(0, list.needed - 1)],
    });
    for (const [name, child] of Object.entries(list.element.shape)) {
      if (!(name in first!) || !(child as z.ZodType).safeParse(undefined).success)
        continue;
      const { [name]: _, ...without } = first!;
      variants.push({ path: `${path}${key}[0].${name}`, data: replace(without) });
    }
    for (const nested of withoutOptionalFields(
      list.element,
      first!,
      `${path}${key}[0].`
    ))
      variants.push({ path: nested.path, data: replace(nested.data) });
  }
  return variants;
}

afterEach(() => {
  document.body.replaceChildren();
});

describe("card contract", () => {
  it("is the contract ui.create checks card data against", () => {
    const committed = resolve(
      import.meta.dirname,
      "../../../../../../systems/apps/salix_agent/priv/dynamic_ui/card-contract.json"
    );
    expect(readFileSync(committed, "utf8")).toBe(
      renderCardContract(cardDataSchemas, cardFrame)
    );
  });

  it("requires at least one bar in the data contract", () => {
    const empty = { title: "Trend", bars: { labels: [], values: [] } };
    expect(cardDataSchemas.trend.safeParse(empty).success).toBe(false);
    expect(() => mount("trend", empty)).toThrow();
    const one = { title: "Trend", bars: { labels: ["Mon"], values: [1] } };
    expect(cardDataSchemas.trend.safeParse(one).success).toBe(true);
    expect(() => mount("trend", one)).not.toThrow();
  });

  it("accepts every fixture, and the templates render it", () => {
    for (const [kind, fixture] of fixtures) {
      expect(cardDataSchemas[kind].safeParse(fixture).error).toBeUndefined();
      expect(() => mount(kind, fixture)).not.toThrow();
    }
  });

  it("marks optional only what the templates render without", () => {
    for (const [kind, fixture] of fixtures) {
      const schema = cardDataSchemas[kind];
      const { needs = [] } = (schema.meta() ?? {}) as { needs?: string[] };
      for (const variant of withoutOptionalFields(schema, fixture as Data)) {
        // Only the list under test may satisfy the card's alternatives.
        const list = variant.path.slice(0, variant.path.indexOf("["));
        const data = { ...variant.data };
        for (const other of needs) if (other !== list) delete data[other];
        const label = `${kind} without ${variant.path}`;
        expect(schema.safeParse(data).error, label).toBeUndefined();
        expect(() => mount(kind, data), label).not.toThrow();
      }
    }
  });
});

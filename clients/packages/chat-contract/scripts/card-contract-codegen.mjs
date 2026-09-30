import { z } from "zod";

/** Titled shapes the manual names inline and defines once. */
const legend = ["tone", "condition", "state", "status", "delta", "url"];

/**
 * The card contract ui.create embeds: one JSON Schema per kind for its data
 * check, and the manual lines that show the Agent the same fields.
 */
export function renderCardContract(schemas, frame) {
  const kinds = Object.fromEntries(
    Object.entries(schemas).map(([kind, schema]) => [
      kind,
      z.toJSONSchema(schema, { target: "draft-7", io: "input" }),
    ])
  );
  const manual = manualLines(kinds, Object.keys(frame));
  return `${JSON.stringify({ kinds, manual }, null, 2)}\n`;
}

function manualLines(kinds, frameKeys) {
  const schemas = Object.values(kinds);
  const titled = new Map();
  for (const schema of schemas) collectTitled(schema, titled);
  const lines = [
    "Fields are text unless a type follows the name. ? marks an optional field.",
    `Every kind accepts ${object(schemas[0], frameKeys)}.`,
    ...legend
      .filter((name) => titled.has(name))
      .map((name) => `${name}: ${definition(titled.get(name))}`),
  ];
  for (const [kind, schema] of Object.entries(kinds)) {
    const own = Object.keys(schema.properties).filter(
      (key) => !frameKeys.includes(key)
    );
    const parts = [
      `${kind}${schema.description ? ` (${schema.description})` : ""}: ${object(schema, own)}`,
    ];
    if (schema.needs) parts.push(`needs ${alternatives(schema.needs)}`);
    for (const [list, other] of schema.sameLength ?? [])
      parts.push(`${list} has as many entries as ${other}`);
    parts.push(`layouts: ${schema.layouts}`);
    lines.push(parts.join("; "));
  }
  return lines;
}

function collectTitled(schema, titled) {
  if (!schema || typeof schema !== "object") return;
  if (legend.includes(schema.title) && !titled.has(schema.title))
    titled.set(schema.title, schema);
  for (const value of Object.values(schema)) {
    if (Array.isArray(value)) for (const item of value) collectTitled(item, titled);
    else collectTitled(value, titled);
  }
}

function definition(schema) {
  if (schema.enum) return schema.enum.join(" | ");
  if (schema.type === "object") return object(schema);
  return schema.description;
}

function object(schema, keys = Object.keys(schema.properties)) {
  const required = new Set(schema.required ?? []);
  const fields = keys.map((key) =>
    field(key, schema.properties[key], required.has(key))
  );
  return `{${fields.join(", ")}}`;
}

function field(name, schema, required) {
  const { type, notes } = describe(schema);
  const shown = type && type !== name ? `: ${type}` : "";
  return `${name}${required ? "" : "?"}${shown}${notes.length ? ` (${notes.join("; ")})` : ""}`;
}

/** A schema's type as the manual writes it; plain text has none. */
function describe(schema) {
  // A titled shape is defined once in the legend.
  if (legend.includes(schema.title)) return { type: schema.title, notes: [] };
  const notes = schema.description ? [schema.description] : [];
  if (schema.anyOf)
    return {
      type: schema.anyOf.map((option) => describe(option).type || "text").join(" or "),
      notes,
    };
  if (schema.enum) return { type: schema.enum.join(" | "), notes };
  switch (schema.type) {
    case "number":
    case "integer":
      return { type: `${schema.type}${range(schema)}`, notes };
    case "boolean":
      return { type: "boolean", notes };
    case "null":
      return { type: "null", notes };
    case "object":
      return { type: object(schema), notes };
    case "array": {
      const count = entries(schema);
      return {
        type: `[${describe(schema.items).type || "text"}]`,
        notes: count ? [count, ...notes] : notes,
      };
    }
    default:
      return { type: schema.format === "date-time" ? "ISO time" : "", notes };
  }
}

function alternatives(names) {
  return names.length > 1
    ? `${names.slice(0, -1).join(", ")} or ${names.at(-1)}`
    : names.join("");
}

function range(schema) {
  // zod bounds every integer by the safe range, which says nothing here.
  const minimum = schema.minimum > Number.MIN_SAFE_INTEGER ? schema.minimum : undefined;
  const maximum = schema.maximum < Number.MAX_SAFE_INTEGER ? schema.maximum : undefined;
  if (minimum !== undefined && maximum !== undefined)
    return ` from ${minimum} to ${maximum}`;
  if (minimum !== undefined) return ` >= ${minimum}`;
  if (maximum !== undefined) return ` <= ${maximum}`;
  return "";
}

function entries({ minItems, limit }) {
  if (minItems && limit)
    return minItems === limit ? `${limit} entries` : `${minItems} to ${limit}`;
  if (limit) return `<= ${limit}`;
  if (minItems) return `>= ${minItems}`;
  return "";
}

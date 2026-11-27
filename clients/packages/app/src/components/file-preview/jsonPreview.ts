import { csvPreviewColumns, csvPreviewRows, type ParsedCsv } from "./csv";

/** Largest JSON/JSONL prefix read for structured preview. */
export const jsonPreviewMaxBytes = 2 * 1024 * 1024;
/** Largest JSON/JSONL prefix passed to syntax-highlighted source view (matches textPreviewLimit). */
export const jsonSourceMaxBytes = 256 * 1024;
/** Most rows the JSON tree draws (open, value and closing-bracket rows), to keep huge payloads responsive. */
export const jsonTreeMaxRows = 2500;
/** Maximum JSONL/NDJSON records parsed for structured preview. */
export const jsonlPreviewMaxRows = csvPreviewRows;
export const jsonlPreviewMaxColumns = csvPreviewColumns;

const jsonNumberBrand = Symbol("JsonNumber");

/** A parsed JSON number keeping its exact source text so >53-bit integers never lose precision. */
export interface JsonNumber {
  readonly [jsonNumberBrand]: true;
  readonly raw: string;
}

export function isJsonNumber(value: unknown): value is JsonNumber {
  return (
    typeof value === "object" &&
    value !== null &&
    jsonNumberBrand in value &&
    typeof (value as JsonNumber).raw === "string"
  );
}

export function jsonNumber(raw: string): JsonNumber {
  return { [jsonNumberBrand]: true, raw };
}

export type JsonValue =
  | null
  | boolean
  | number
  | JsonNumber
  | string
  | JsonValue[]
  | { [key: string]: JsonValue };

export type JsonContainer = JsonValue[] | { [key: string]: JsonValue };

export function isJsonContainer(value: JsonValue): value is JsonContainer {
  return value !== null && typeof value === "object" && !isJsonNumber(value);
}

const maxJsonDepth = 512;

/**
 * Parses RFC 8259 JSON while preserving the exact source text of every number token (`JsonNumber`),
 * so 64-bit IDs such as `12345678901234567890` render and copy without IEEE-754 rounding.
 */
export function parseJsonPreservingNumbers(text: string): JsonValue {
  const len = text.length;
  let pos = 0;

  const skipWs = () => {
    while (pos < len) {
      const ch = text.charCodeAt(pos);
      if (ch === 0x20 || ch === 0x09 || ch === 0x0a || ch === 0x0d) {
        pos += 1;
      } else {
        break;
      }
    }
  };

  const parseString = (): string => {
    const start = pos;
    pos += 1; // opening '"'
    let hasEscape = false;
    while (pos < len) {
      const ch = text.charCodeAt(pos);
      if (ch === 0x22) {
        pos += 1;
        return hasEscape
          ? (JSON.parse(text.slice(start, pos)) as string)
          : text.slice(start + 1, pos - 1);
      }
      if (ch === 0x5c) {
        hasEscape = true;
        pos += 2;
        if (pos > len) throw new SyntaxError("unterminated escape");
        continue;
      }
      if (ch < 0x20) throw new SyntaxError("unescaped control character in string");
      pos += 1;
    }
    throw new SyntaxError("unterminated string");
  };

  const parseNumber = (): JsonNumber => {
    const start = pos;
    if (text.charCodeAt(pos) === 0x2d) pos += 1; // '-'
    if (pos >= len) throw new SyntaxError("invalid number");
    const first = text.charCodeAt(pos);
    if (first === 0x30) {
      pos += 1;
    } else if (first >= 0x31 && first <= 0x39) {
      pos += 1;
      while (pos < len) {
        const ch = text.charCodeAt(pos);
        if (ch >= 0x30 && ch <= 0x39) pos += 1;
        else break;
      }
    } else {
      throw new SyntaxError("invalid number");
    }
    if (pos < len && text.charCodeAt(pos) === 0x2e) {
      pos += 1;
      const fracStart = pos;
      while (pos < len) {
        const ch = text.charCodeAt(pos);
        if (ch >= 0x30 && ch <= 0x39) pos += 1;
        else break;
      }
      if (pos === fracStart) throw new SyntaxError("invalid fraction");
    }
    if (pos < len) {
      const exp = text.charCodeAt(pos);
      if (exp === 0x65 || exp === 0x45) {
        pos += 1;
        if (pos < len) {
          const sign = text.charCodeAt(pos);
          if (sign === 0x2b || sign === 0x2d) pos += 1;
        }
        const expStart = pos;
        while (pos < len) {
          const ch = text.charCodeAt(pos);
          if (ch >= 0x30 && ch <= 0x39) pos += 1;
          else break;
        }
        if (pos === expStart) throw new SyntaxError("invalid exponent");
      }
    }
    return jsonNumber(text.slice(start, pos));
  };

  const parseValue = (depth: number): JsonValue => {
    if (depth > maxJsonDepth) throw new SyntaxError("nesting too deep");
    skipWs();
    if (pos >= len) throw new SyntaxError("unexpected end of JSON");
    const ch = text.charCodeAt(pos);
    if (ch === 0x22) return parseString();
    if (ch === 0x7b) {
      pos += 1;
      skipWs();
      const obj: { [key: string]: JsonValue } = {};
      if (pos < len && text.charCodeAt(pos) === 0x7d) {
        pos += 1;
        return obj;
      }
      for (;;) {
        skipWs();
        if (pos >= len || text.charCodeAt(pos) !== 0x22) {
          throw new SyntaxError("expected property name");
        }
        const key = parseString();
        skipWs();
        if (pos >= len || text.charCodeAt(pos) !== 0x3a) {
          throw new SyntaxError("expected ':'");
        }
        pos += 1;
        const val = parseValue(depth + 1);
        Object.defineProperty(obj, key, {
          value: val,
          enumerable: true,
          writable: true,
          configurable: true,
        });
        skipWs();
        if (pos >= len) throw new SyntaxError("unterminated object");
        const sep = text.charCodeAt(pos);
        if (sep === 0x7d) {
          pos += 1;
          return obj;
        }
        if (sep !== 0x2c) throw new SyntaxError("expected ',' or '}'");
        pos += 1;
      }
    }
    if (ch === 0x5b) {
      pos += 1;
      skipWs();
      const arr: JsonValue[] = [];
      if (pos < len && text.charCodeAt(pos) === 0x5d) {
        pos += 1;
        return arr;
      }
      for (;;) {
        arr.push(parseValue(depth + 1));
        skipWs();
        if (pos >= len) throw new SyntaxError("unterminated array");
        const sep = text.charCodeAt(pos);
        if (sep === 0x5d) {
          pos += 1;
          return arr;
        }
        if (sep !== 0x2c) throw new SyntaxError("expected ',' or ']'");
        pos += 1;
      }
    }
    if (ch === 0x74 && text.startsWith("true", pos)) {
      pos += 4;
      return true;
    }
    if (ch === 0x66 && text.startsWith("false", pos)) {
      pos += 5;
      return false;
    }
    if (ch === 0x6e && text.startsWith("null", pos)) {
      pos += 4;
      return null;
    }
    if (ch === 0x2d || (ch >= 0x30 && ch <= 0x39)) {
      return parseNumber();
    }
    throw new SyntaxError(`unexpected token at ${pos}`);
  };

  const value = parseValue(0);
  skipWs();
  if (pos !== len) throw new SyntaxError("unexpected trailing content");
  return value;
}

/** Serializes a parsed `JsonValue` back to JSON without losing `JsonNumber` precision. */
export function formatJsonValue(value: JsonValue, indent = 0, level = 0): string {
  if (isJsonNumber(value)) return value.raw;
  if (!isJsonContainer(value)) return JSON.stringify(value);
  if (Array.isArray(value)) {
    if (value.length === 0) return "[]";
    if (indent <= 0) return `[${value.map((item) => formatJsonValue(item)).join(",")}]`;
    const pad = " ".repeat(indent * (level + 1));
    const closePad = " ".repeat(indent * level);
    return `[\n${value.map((item) => `${pad}${formatJsonValue(item, indent, level + 1)}`).join(",\n")}\n${closePad}]`;
  }
  const entries = Object.entries(value);
  if (entries.length === 0) return "{}";
  if (indent <= 0) {
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${formatJsonValue(v)}`).join(",")}}`;
  }
  const pad = " ".repeat(indent * (level + 1));
  const closePad = " ".repeat(indent * level);
  return `{\n${entries.map(([k, v]) => `${pad}${JSON.stringify(k)}: ${formatJsonValue(v, indent, level + 1)}`).join(",\n")}\n${closePad}}`;
}

/** A row of the JSON tree: a container's opening line, a value, or a container's closing bracket. */
export type JsonTreeRow =
  | {
      kind: "open";
      /** Identifies the node across renders (its keys from the root). */
      path: string;
      depth: number;
      /** The key in its object, or the index in its array; none for the root. */
      label: JsonTreeLabel | undefined;
      value: JsonContainer;
      expanded: boolean;
      /** Its keys or items. */
      count: number;
    }
  | {
      kind: "value";
      path: string;
      depth: number;
      label: JsonTreeLabel | undefined;
      /** A primitive, or an empty container. */
      value: JsonValue;
    }
  | { kind: "close"; path: string; depth: number; array: boolean };

export type JsonTreeLabel = { text: string; index: boolean };

/**
 * The rows the JSON tree shows, in order, for the branches `isExpanded` opens: at most `maxRows`. Computed before
 * anything renders, so the tree knows it was cut (`capped`) and says so instead of ending without its closing brackets.
 */
export function flattenJsonTree(
  root: JsonValue,
  isExpanded: (path: string, depth: number) => boolean,
  maxRows: number = jsonTreeMaxRows
): { rows: JsonTreeRow[]; capped: boolean } {
  const rows: JsonTreeRow[] = [];
  let capped = false;
  const push = (row: JsonTreeRow) => {
    if (rows.length >= maxRows) {
      capped = true;
      return false;
    }
    rows.push(row);
    return true;
  };
  const visit = (
    value: JsonValue,
    path: string,
    depth: number,
    label: JsonTreeLabel | undefined
  ): boolean => {
    if (!isJsonContainer(value))
      return push({ kind: "value", path, depth, label, value });
    const array = Array.isArray(value);
    const keys = array ? null : Object.keys(value);
    const count = array ? value.length : keys!.length;
    if (count === 0) return push({ kind: "value", path, depth, label, value });
    const expanded = isExpanded(path, depth);
    if (!push({ kind: "open", path, depth, label, value, expanded, count }))
      return false;
    if (!expanded) return true;
    for (let i = 0; i < count; i += 1) {
      const key = array ? String(i) : keys![i]!;
      const child = array ? value[i]! : value[key]!;
      // Keys are joined by a unit separator, which keys almost never hold: a clash would only share an open state.
      if (!visit(child, `${path}\u001f${key}`, depth + 1, { text: key, index: array }))
        return false;
    }
    return push({ kind: "close", path, depth, array });
  };
  visit(root, "$", 0, undefined);
  return { rows, capped };
}

export interface ParsedJsonLines {
  /** Non-empty parsed records when lines are tabular objects; rendered via table view. */
  table: ParsedCsv | undefined;
  /** Parsed values when lines are heterogeneous or scalar JSON values. */
  records: Array<{ line: number; value: JsonValue }>;
  /** True when more lines remain beyond the byte or row limit. */
  rowsCut: boolean;
  columnsCut: boolean;
  /** True when parsing failed on non-empty lines so caller should fall back to raw source. */
  invalid: boolean;
}

const minColumnWidth = 72;
const maxColumnWidth = 320;

function displayLength(value: string): number {
  const firstLine = value.split(/\r\n|\n|\r/u, 1)[0] ?? "";
  let total = 0;
  for (const ch of firstLine) {
    const code = ch.codePointAt(0) ?? 0;
    total += code >= 0x1100 ? 1.85 : 1;
  }
  return total;
}

function formatCellValue(value: JsonValue | undefined): string {
  if (value === undefined || value === null) return "";
  if (typeof value === "string") return value;
  if (isJsonNumber(value)) return value.raw;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return inlineJson(value);
}

/** JSON on one line with a space after each `,` and `:`, so a nested value in a cell reads as words do. */
function inlineJson(value: JsonValue): string {
  if (isJsonNumber(value)) return value.raw;
  if (!isJsonContainer(value)) return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(inlineJson).join(", ")}]`;
  const fields = Object.entries(value).map(
    ([key, child]) => `${JSON.stringify(key)}: ${inlineJson(child)}`
  );
  return `{${fields.join(", ")}}`;
}

/**
 * Parses JSONL / NDJSON text into either a tabular projection (when records are plain objects) or a list of parsed
 * JSON values. Drops an incomplete trailing line when the input was sliced at a byte boundary.
 */
export function parseJsonLines(
  text: string,
  {
    maxRows = jsonlPreviewMaxRows,
    maxColumns = jsonlPreviewMaxColumns,
    byteTruncated = false,
  }: {
    maxRows?: number;
    maxColumns?: number;
    byteTruncated?: boolean;
  } = {}
): ParsedJsonLines {
  const rawLines = text.replace(/^\uFEFF/u, "").split(/\r\n|\n|\r/u);
  let rowsCut = false;
  if (byteTruncated) {
    if (rawLines.length > 1) rawLines.pop();
    rowsCut = true;
  }

  const records: Array<{ line: number; value: JsonValue }> = [];
  for (let i = 0; i < rawLines.length; i += 1) {
    const trimmed = rawLines[i]!.trim();
    if (!trimmed) continue;
    if (records.length >= maxRows) {
      rowsCut = true;
      break;
    }
    try {
      records.push({ line: i + 1, value: parseJsonPreservingNumbers(trimmed) });
    } catch {
      return {
        table: undefined,
        records: [],
        rowsCut,
        columnsCut: false,
        invalid: true,
      };
    }
  }

  if (records.length === 0) {
    return {
      table: undefined,
      records: [],
      rowsCut,
      columnsCut: false,
      invalid: false,
    };
  }

  const allObjects = records.every(
    ({ value }) => isJsonContainer(value) && !Array.isArray(value)
  );
  if (!allObjects) {
    return { table: undefined, records, rowsCut, columnsCut: false, invalid: false };
  }

  const headers: string[] = [];
  const seenKeys = new Set<string>();
  let columnsCut = false;
  for (const { value } of records) {
    for (const key of Object.keys(value as Record<string, JsonValue>)) {
      if (seenKeys.has(key)) continue;
      if (headers.length >= maxColumns) {
        columnsCut = true;
        continue;
      }
      seenKeys.add(key);
      headers.push(key);
    }
  }

  if (headers.length === 0) {
    return { table: undefined, records, rowsCut, columnsCut: false, invalid: false };
  }

  const rows = records.map(({ value }) => {
    const obj = value as Record<string, JsonValue>;
    return headers.map((key) => formatCellValue(obj[key]));
  });

  const numericSample = Math.min(records.length, 100);
  const numericColumns = headers.map((key) => {
    let seen = 0;
    for (let r = 0; r < numericSample; r += 1) {
      const cell = (records[r]!.value as Record<string, JsonValue>)[key];
      if (cell === undefined || cell === null) continue;
      if (typeof cell !== "number" && !isJsonNumber(cell)) return false;
      seen += 1;
    }
    return seen > 0;
  });

  const widthSample = Math.min(rows.length, 50);
  const columnWidths = headers.map((header, c) => {
    let widest = displayLength(header) * 1.05;
    for (let r = 0; r < widthSample; r += 1) {
      const len = displayLength(rows[r]![c]!);
      if (len > widest) widest = len;
    }
    return Math.round(
      Math.min(maxColumnWidth, Math.max(minColumnWidth, widest * 7.5 + 24))
    );
  });

  return {
    table: {
      headers,
      rows,
      columnCount: headers.length,
      columnWidths,
      numericColumns,
      rowsCut,
      columnsCut,
    },
    records,
    rowsCut,
    columnsCut,
    invalid: false,
  };
}

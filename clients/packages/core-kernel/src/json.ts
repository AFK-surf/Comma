// JSON as the cores compare and send it: objects' keys sorted (as serde_json without preserve_order keeps them), so
// the same value is the same text on every host, and equality by keys whatever their order.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function utf8(text: string): Uint8Array {
  return encoder.encode(text);
}

export function fromUtf8(bytes: Uint8Array): string {
  return decoder.decode(bytes);
}

/// A JSON value.
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type JsonObject = { [key: string]: Json };

export function isObject(v: unknown): v is JsonObject {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

/// Equality of JSON values: objects by their keys whatever the order, numbers by value.
export function equal(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object")
    return false;
  if (Array.isArray(a)) {
    if (!Array.isArray(b) || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (!equal(a[i], b[i])) return false;
    return true;
  }
  if (Array.isArray(b)) return false;
  const ak = Object.keys(a);
  const bk = Object.keys(b);
  if (ak.length !== bk.length) return false;
  for (const k of ak) {
    if (!Object.prototype.hasOwnProperty.call(b, k)) return false;
    if (!equal((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]))
      return false;
  }
  return true;
}

/// Keys sorted at every level.
export function sorted(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sorted);
  if (isObject(v)) {
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(v).toSorted(compareKeys)) out[k] = sorted(v[k]);
    return out;
  }
  return v;
}

/// Strings by their code points (UTF-8 byte order), not UTF-16 units.
export function compareKeys(a: string, b: string): number {
  if (a === b) return 0;
  const la = a.length;
  const lb = b.length;
  for (let i = 0, j = 0; i < la && j < lb; ) {
    const ca = a.codePointAt(i)!;
    const cb = b.codePointAt(j)!;
    if (ca !== cb) return ca < cb ? -1 : 1;
    i += ca > 0xffff ? 2 : 1;
    j += cb > 0xffff ? 2 : 1;
  }
  return la < lb ? -1 : la > lb ? 1 : 0;
}

/// JSON text with keys sorted.
export function toJson(v: unknown): string {
  return JSON.stringify(sorted(v));
}

export function toJsonBytes(v: unknown): Uint8Array {
  return utf8(toJson(v));
}

/// JSON from bytes or text; undefined when it is not JSON.
export function parseJson(
  bytes: Uint8Array | string | null | undefined
): Json | undefined {
  if (bytes === null || bytes === undefined) return undefined;
  try {
    return JSON.parse(typeof bytes === "string" ? bytes : fromUtf8(bytes)) as Json;
  } catch {
    return undefined;
  }
}

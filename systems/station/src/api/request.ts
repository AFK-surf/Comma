// A request to the admin API as the station takes it from the mesh (or another door), and its answer.
import type { Viewer } from "../mesh/credential.ts";
import { type Lang, langOf } from "../ops/i18n.ts";

export type Request = {
  method: string;
  /// After /admin/api, without the query.
  path: string;
  query: [string, string][];
  /// The query as asked (`?…`, or empty): what a preview passes on as it is.
  search?: string;
  headers: Record<string, string>;
  body: Buffer;
  viewer: Viewer;
  lang: Lang;
};

export type Answer = {
  status: number;
  headers: Record<string, string>;
  /// Whole, or as it comes (an event stream).
  body: Buffer | AsyncIterable<Buffer>;
};

/// The language a core asks in: its `stillfail-lang`; Chinese for a core from before languages (lang.rs `of_core`).
export function langOfCore(headers: Record<string, string>): Lang {
  const said = Object.entries(headers).find(([k]) => k.toLowerCase() === "stillfail-lang");
  return said ? langOf(said[1]) : "zh";
}

/// admin/mod.rs `percent_decode`: `%xx` a byte, `+` a space, the rest as it is; then UTF-8, lossily.
export function percentDecode(s: string): string {
  const bytes = Buffer.from(s, "utf8");
  const out: number[] = [];
  for (let i = 0; i < bytes.length; ) {
    const hex = bytes.subarray(i + 1, i + 3).toString("latin1");
    if (bytes[i] === 0x25 && /^[0-9a-fA-F]{2}$/.test(hex)) {
      out.push(parseInt(hex, 16));
      i += 3;
    } else {
      out.push(bytes[i] === 0x2b ? 0x20 : bytes[i]);
      i += 1;
    }
  }
  return new TextDecoder("utf-8").decode(Buffer.from(out));
}

/// admin/mod.rs `query_pairs`.
export const queryPairs = (query: string): [string, string][] =>
  query
    .split("&")
    .filter((p) => p !== "")
    .map((p) => {
      const at = p.indexOf("=");
      return at < 0 ? [percentDecode(p), ""] : [percentDecode(p.slice(0, at)), percentDecode(p.slice(at + 1))];
    });

/// The first value of a name, as `Asked::param` has it.
export const param = (r: Request, name: string) => r.query.find(([k]) => k === name)?.[1];

const JSON_HEADERS = { "content-type": "application/json", "cache-control": "no-store" };

export const json = (status: number, text: string): Answer => ({ status, headers: { ...JSON_HEADERS }, body: Buffer.from(text) });
export const error = (status: number, message: string): Answer => json(status, JSON.stringify({ error: message }));

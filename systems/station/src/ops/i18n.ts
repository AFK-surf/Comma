// The words people read, in their language: client/i18n/catalog (its README says how it is read), its
// station part (everything the station says is under `station.`; the rest is the clients'). `{name}` takes the value
// given as `name`; `{"one", "other"}` is chosen by `n` (1: one). A key a language lacks is said in Chinese; one neither
// has is the key.
import zhStation from "../../i18n/zh/station.json" with { type: "json" };
import enStation from "../../i18n/en/station.json" with { type: "json" };

export type Lang = "zh" | "en";
type Words = Record<string, string | { one?: string; other: string }>;

const ZH: Words = zhStation;
const EN: Words = enStation;

/// Chinese for Chinese, English for any other; Chinese when nothing is said.
export function langOf(locale: string | null | undefined): Lang {
  const l = (locale ?? "").trim().toLowerCase();
  return !l || l.startsWith("zh") ? "zh" : "en";
}

let station: Lang = "zh";
/// The station's own language (config.json `language`), for what it says on this machine.
export const setStationLang = (language: string | null | undefined) => (station = langOf(language));
export const stationLang = () => station;

export function tr(lang: Lang, key: string, args: Record<string, unknown> = {}): string {
  const found = (lang === "en" ? EN : ZH)[key] ?? ZH[key];
  let text: string;
  if (typeof found === "string") text = found;
  else if (found) text = ("n" in args && String(args.n).trim() === "1" ? found.one : found.other) ?? found.other ?? key;
  else text = key;
  return fill(text, args);
}

/// `{name}` filled; one not given, and a `{` that opens no name, left as they are.
function fill(text: string, args: Record<string, unknown>): string {
  if (Object.keys(args).length === 0 || !text.includes("{")) return text;
  return text.replace(/\{([A-Za-z0-9_]*)\}/g, (all, name) => (name in args ? String(args[name]) : all));
}

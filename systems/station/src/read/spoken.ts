// The language the read being answered speaks in (lang.rs `spoken()`), for the reads outside views.ts: their routes
// pass the request's (`lang` in a read's args) and the op sets it before it answers (one read at a time in a reader).
import { type Lang, tr as translate } from "../ops/i18n.ts";

let lang: Lang = "zh";
export const setLang = (l: Lang | undefined) => (lang = l ?? "zh");
export const spoken = () => lang;
/// `t!(spoken(); key, args…)`.
export const tr = (key: string, args: Record<string, string> = {}) => translate(lang, key, args);

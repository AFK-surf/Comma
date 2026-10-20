// The agents' tool arguments as the station reads them (the Rust station's hub.rs, its argument functions): how a turn ends
// (`kind`, in today's words and those from before), what goes with it (`need`, `done`, `about`), the card a post carries
// (`card`, or `options` from before cards; JSON text from a runtime whose tool list is older), and how posts with files
// are kept. Every rule and every word of what an agent is told when it is refused is the Rust station's.
import { type DeclaredState, parseDeclared } from "./actor.ts";
import { tr, stationLang } from "../ops/i18n.ts";
import type { Attachment } from "../store/store.ts";

type Json = any;
export type Args = Record<string, Json>;

/// A value as JavaScript's String() writes it (hub.rs `js_string`), for arguments given as another type than asked.
export const jsString = (value: Json): string => (typeof value === "string" ? value : value === null ? "null" : JSON.stringify(value));

/// A number, or a string holding one (hub.rs `js_number`).
export function jsNumber(value: Json): number | null {
  if (typeof value === "number") return value;
  if (typeof value !== "string") return null;
  const t = value.trim();
  if (/^[+-]?(inf|infinity)$/i.test(t)) return t.startsWith("-") ? -Infinity : Infinity;
  if (/^[+-]?nan$/i.test(t)) return NaN;
  return /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(t) ? Number(t) : null;
}

/// serde_json's Display of a value, as error messages quote what was given.
const shown = (value: Json): string => JSON.stringify(value);

/// How long an agent may say it waits (chat_state "waiting").
export const MIN_WAIT_SECONDS = 10;
export const MAX_WAIT_SECONDS = 3600;
/// How many answers a decision may offer.
export const MAX_OPTIONS = 6;
/// The kinds of card a post can carry.
const CARDS = ["options", "text"];
/// How long a text card's placeholder may be, in characters.
const MAX_PLACEHOLDER = 80;
/// How many letters (or characters) all_done's `done` has at least.
const MIN_REASON = 6;

const chars = (s: string) => Array.from(s).length;
const take = (s: string, n: number) => Array.from(s).slice(0, n).join("");

/// In which words a turn's state was given: today's (all_done, need_help, waiting); from before all_done and need_help
/// (final, block: a session whose instructions are older); need_decision, from before cards (a post with an options
/// card that ends the turn need_help).
export type Said = "now" | "before" | "decision";

export const declaredStr = (kind: DeclaredState): string => (kind.kind === "all_done" ? "all_done" : kind.kind === "need_help" ? "need_help" : "waiting");

/// A state in the words agents are told (need_human is kept as need_help, the word clients read).
export const saidAs = (kind: DeclaredState): string => (kind.kind === "need_help" ? "need_human" : declaredStr(kind));

/// How a post or chat_state ends the turn (`kind`), and in which words. Waiting is chat_state's own.
export function stateArg(value: Json): [DeclaredState, Said] | null {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value === "string" && value !== "waiting") {
    const kind = parseDeclared(value, 0);
    if (kind) return [kind, value === "final" || value === "block" ? "before" : value === "need_decision" ? "decision" : "now"];
  }
  throw new Error(`kind must be "all_done" or "need_human" (or "waiting", with chat_state), got ${shown(value)}`);
}

/// Whether all_done's `done` gives a reason, not only the word: at least a few characters, and not one of the words
/// that say only that it is done.
export function isReason(done: string): boolean {
  const bare = Array.from(done)
    .filter((c) => /^[\p{Alphabetic}\p{N}]$/u.test(c))
    .join("")
    .toLowerCase();
  const EMPTY = ["做完了", "已完成", "全部完成", "都完成了", "done", "ok", "alldone", "finished", "allfinished"];
  return chars(bare) >= MIN_REASON && !EMPTY.includes(bare);
}

/// The turn's words kept with it (turns.need): what a need_help turn needs of a person (`need`), or what an all_done
/// one leaves the chat with (`done`). Each goes only with its kind, and is required with it, unless the kind is given in
/// the words from before (block, final, need_decision: a session from before them).
export function needArg(args: Args, kind: DeclaredState, said: Said): string | null {
  const text = (k: string) => {
    if (args[k] === undefined) return null;
    const t = jsString(args[k]).trim();
    return t === "" ? null : t;
  };
  const [need, done] = [text("need"), text("done")];
  if (need !== null && kind.kind !== "need_help") throw new Error('need goes only with kind "need_human"');
  if (done !== null && kind.kind !== "all_done") throw new Error('done goes only with kind "all_done"');
  if (done !== null && !isReason(done)) {
    throw new Error(
      "done must say why nothing in the chat is left, so people can trust it: what was finished and where it landed or how it was confirmed (a commit, a release, a person's confirmation, the answer given), e.g. 已合进 main 82f108a5，测试版 1389 已发，你确认过滑动可以; not just that it is done",
    );
  }
  if (kind.kind === "need_help" && need === null && said === "now") throw new Error("need is required for need_human: what the person has to give, do or decide, in one sentence");
  if (kind.kind === "all_done" && done === null && said === "now") {
    throw new Error("done is required for all_done: why nothing in the chat is left, with the evidence (e.g. 已合进 main 82f108a5，测试版 1389 已发，你确认过滑动可以)");
  }
  if (kind.kind === "need_help") return need;
  if (kind.kind === "all_done") return done;
  return null;
}

/// The ts `about` names, if it is given.
export function aboutTs(args: Args): string | null {
  const about = args.about;
  if (about === undefined || about === null) return null;
  const ts = jsString(about).trim();
  return ts === "" ? null : ts;
}

/// A post's first line, without markup, cut to about 40 characters: what a decision asked in the words from before
/// needs.
export function firstLine(text: string): string {
  const first = text.split("\n").map((l) => l.trim()).find((l) => l !== "") ?? "";
  const clean = first.replaceAll("**", "").replaceAll("__", "").replaceAll("`", "").replace(/^[#>\-* ]+/, "").trim();
  const cut = take(clean, 40);
  return chars(clean) > 40 ? `${cut.trimEnd()}…` : cut;
}

const isObject = (v: Json) => v !== null && typeof v === "object" && !Array.isArray(v);

/// The answers an options card offers (its `options`, or chat_post `options` as said before cards), as kept with its
/// post: `[{label, detail?, recommended?, action?}]`, each label trimmed. 1 to 6, labels not empty and not repeated, at
/// most one recommended. A runtime whose tool list is from before the parameter sends it as JSON text: read too.
export function optionsArg(value: Json): Json[] | null {
  let parsed: Json = undefined;
  if (typeof value === "string" && value.trim() !== "") {
    try {
      parsed = JSON.parse(value);
    } catch {
      throw new Error("options must be an array of {label, detail?, recommended?}");
    }
  }
  const list = parsed !== undefined ? parsed : value;
  if (list === undefined || list === null || typeof list === "string") return null;
  if (!Array.isArray(list)) throw new Error("options must be an array of {label, detail?, recommended?}");
  if (list.length === 0 || list.length > MAX_OPTIONS) throw new Error(`options must have 1 to ${MAX_OPTIONS} answers, got ${list.length}`);
  const out: Json[] = [];
  const labels: string[] = [];
  list.forEach((given, i) => {
    let o: Json;
    // A bare phrase is its label.
    if (typeof given === "string") o = { label: given };
    else if (isObject(given)) o = given;
    else throw new Error(`options[${i}] must be an object {label, detail?, recommended?}`);
    const label = o.label === undefined ? "" : jsString(o.label).trim();
    if (label === "") throw new Error(`options[${i}].label is empty: a short phrase that reads on its own`);
    if (labels.includes(label)) throw new Error(`options[${i}].label repeats ${JSON.stringify(label)}: each answer says something else`);
    labels.push(label);
    const kept: Json = { label };
    const detail = o.detail === undefined ? "" : jsString(o.detail).trim();
    if (detail !== "") kept.detail = detail;
    if (o.recommended === true || o.recommended === "true") kept.recommended = true;
    if (o.action !== undefined) {
      if (o.action === "reply" || o.action === "close") kept.action = o.action;
      else throw new Error(`options[${i}].action must be reply or close`);
    }
    out.push(kept);
  });
  if (out.filter((o) => o.recommended !== undefined).length > 1) throw new Error("only one option may be recommended");
  return out;
}

export const optionsCard = (options: Json[]): Json => ({ type: "options", options });

/// The card a post carries (chat_post `card`, or its `options` as said before cards: an options card), as kept with it:
/// `{type: "options", options}` or `{type: "text", placeholder?}`, with its `assignee`. A card of a type not known is
/// refused, naming those that are. A runtime whose tool list is from before the parameter sends it as JSON text: read
/// too.
export function cardArg(card: Json, options: Json): Json | null {
  const shape = 'card must be an object: {"type": "options", "options": [{label, detail?, recommended?}]} or {"type": "text", "placeholder"?}';
  let given: Json = null;
  if (card === undefined || card === null) given = null;
  else if (typeof card === "string") {
    if (card.trim() === "") given = null;
    else {
      try {
        given = JSON.parse(card);
      } catch {
        throw new Error(shape);
      }
    }
  } else given = card;
  const legacy = optionsArg(options);
  if (given === null) return legacy === null ? null : optionsCard(legacy);
  if (legacy !== null) throw new Error('give the options in card ({"type": "options", "options": [...]}), not also as options');
  if (!isObject(given)) throw new Error(shape);
  const kind = given.type === undefined ? "" : jsString(given.type).trim();
  let kept: Json;
  if (kind === "options") {
    const options = optionsArg(given.options);
    if (options === null) throw new Error(`an options card has options: 1 to ${MAX_OPTIONS} answers {label, detail?, recommended?}`);
    kept = optionsCard(options);
  } else if (kind === "text") {
    const placeholder = given.placeholder === undefined ? "" : jsString(given.placeholder).trim();
    if (chars(placeholder) > MAX_PLACEHOLDER) throw new Error(`a text card's placeholder is at most ${MAX_PLACEHOLDER} characters: a hint of what to write`);
    kept = { type: "text" };
    if (placeholder !== "") kept.placeholder = placeholder;
  } else if (kind === "") throw new Error(`a card says its type: one of ${CARDS.join(", ")}`);
  else throw new Error(`unknown card type ${JSON.stringify(kind)}: the types known are ${CARDS.join(", ")}`);
  if (given.assignee !== undefined) {
    const v = typeof given.assignee === "string" ? given.assignee.trim() : null;
    const parts = v?.split("@") ?? [];
    const ok = v !== null && parts.length === 2 && parts[0] !== "" && parts[1] !== "" && !/\s/.test(v) && Buffer.byteLength(v) <= 254;
    if (!ok) throw new Error("card.assignee must be the decision maker's email, not a display name");
    kept.assignee = v!.toLowerCase();
  }
  return kept;
}

/// What chat_post says of the answers it offered.
export function optionsSaid(options: Json): string {
  const labels = (Array.isArray(options) ? options : []).map((o: Json) => {
    const label = typeof o?.label === "string" ? o.label : "";
    return o?.recommended !== undefined ? `${label} (recommended)` : label;
  });
  return ` People can pick: ${labels.join("; ")}; a reply option reaches you as their message quoting this one with the option's label (action=close ends the wait silently), and anything they write instead is their answer too.`;
}

/// What chat_post says of the card it posted.
export const cardSaid = (card: Json): string =>
  card?.type === "options"
    ? optionsSaid(card.options)
    : " People can write their answer in the card's field; it reaches you as their message quoting this one, and anything they write in the chat instead is their answer too.";

const isHtml = (f: Attachment) => {
  const name = f.name.toLowerCase();
  return name.endsWith(".html") || name.endsWith(".htm");
};

/// What still.fail keeps of a post to Slack: the text with each HTML file not yet placed in it placed on a line of its
/// own (drawn there as a visualization, as the agent would place it in a still.fail chat).
export function placeFigures(text: string, files: Attachment[]): string {
  let kept = text;
  for (const f of files.filter(isHtml)) {
    if (!kept.includes(`](${f.name})`)) kept = kept === "" ? `[${f.name}](${f.name})` : `${kept}\n\n[${f.name}](${f.name})`;
  }
  return kept;
}

/// A post with files to a Slack thread that cannot take them (an app without files:write): what Slack is sent, the text
/// with a link to the session in still.fail that opens its first figure (else its first file) on its own; and what
/// still.fail keeps (placeFigures).
export function slackWithFiles(text: string, files: Attachment[], link: string): [string, string] {
  const figure = files.find(isHtml);
  const t = (key: string) => tr(stationLang(), key);
  const what = figure ? (files.length === 1 ? t("station.slack.viewFigure") : t("station.slack.viewFigureAndFiles")) : t("station.slack.viewFiles");
  const opened = figure ?? files[0];
  const target = opened ? `${link}?file=${encodeURIComponent(opened.name)}` : link;
  const posted = text === "" ? `<${target}|${what}>` : `${text}\n\n<${target}|${what}>`;
  return [posted, placeFigures(text, files)];
}

/// `-stop`, alone or after mentions.
export function isStopCommand(text: string): boolean {
  let rest = text.trim();
  while (rest.startsWith("<@")) {
    const after = rest.slice(2);
    const end = after.indexOf(">");
    if (end < 0) return false;
    const id = after.slice(0, end);
    if (id === "" || !/^[A-Za-z0-9]+$/.test(id)) return false;
    rest = after.slice(end + 1).trimStart();
  }
  return rest.toLowerCase() === "-stop";
}

/// A Slack Web API method's shape: family.method, lower camel case.
export function isSlackMethod(method: string): boolean {
  const [first, ...rest] = method.split(".");
  return /^[a-z][A-Za-z]*$/.test(first ?? "") && rest.length > 0 && rest.every((p) => /^[A-Za-z]+$/.test(p));
}

/// Methods that land in a thread: the threads rule applies to them.
export const WRITES = [
  "chat.postMessage",
  "chat.postEphemeral",
  "chat.scheduleMessage",
  "chat.update",
  "chat.delete",
  "chat.meMessage",
  "reactions.add",
  "reactions.remove",
  "pins.add",
  "pins.remove",
  "files.completeUploadExternal",
  "assistant.threads.",
];

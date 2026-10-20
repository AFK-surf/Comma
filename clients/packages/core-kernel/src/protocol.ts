// Messages between a UI and the core. A UI calls by name (`{id, call, params}`), subscribes to a topic
// (`{id, subscribe: {topic, …params}, keyed}`), lets one go (`{id, unsubscribe: true}`) or stops a call under way
// (`{id, cancel: true}`). The core answers a call once (`{id, ok}` or `{id, error}`; `{id, value}` before that says how
// far it got) and a subscription with its whole value first, then what changed (`{id, delta}`), or its error.
import type { AnyOp } from "./collections.ts";
import type { ErrorBody } from "./error.ts";
import { isObject, toJson } from "./json.ts";

/// One connected UI (a tab, a window).
export type ClientId = number;
/// Chosen by the UI; answers and subscription values carry it back.
export type RequestId = number;

/// UI → core.
export type ClientMessage =
  | { kind: "call"; id: RequestId; call: string; params: unknown }
  | { kind: "subscribe"; id: RequestId; subscribe: Topic; keyed?: boolean }
  | { kind: "unsubscribe"; id: RequestId }
  | { kind: "cancel"; id: RequestId };

/// core → UI, as it goes on the wire.
export type CoreMessage =
  | { id: RequestId; ok: unknown }
  | { id: RequestId; error: ErrorBody }
  | { id: RequestId; value: unknown }
  | { id: RequestId; delta: AnyOp[] };

/// What a UI can subscribe to: `{ topic, …params }`.
export type Topic = { topic: string; [param: string]: unknown };

export type Param = "string" | "int" | "bool";
/// How each param is kept: `req` must be given; `def` is filled in when absent (empty, false or 0); `opt` is null
/// when absent; `skip` is left out when absent.
export type ParamSpec = [Param, "req" | "def" | "opt" | "skip"];
/// A topic's params by name.
export type TopicParams = Record<string, ParamSpec>;
/// Every topic a core has, by name.
export type TopicSpecs = Record<string, TopicParams>;

function fits(value: unknown, kind: Param): boolean {
  switch (kind) {
    case "string":
      return typeof value === "string";
    case "bool":
      return typeof value === "boolean";
    case "int":
      return typeof value === "number" && Number.isSafeInteger(value);
  }
}

/// A topic as the UI said it, with its params as `specs` declares them (unknown params dropped, defaults filled), or
/// null when it is none the core has.
export function parseTopic(raw: unknown, specs: TopicSpecs): Topic | null {
  if (!isObject(raw) || typeof raw.topic !== "string") return null;
  const spec = Object.prototype.hasOwnProperty.call(specs, raw.topic)
    ? specs[raw.topic]
    : undefined;
  if (!spec) return null;
  const out: Topic = { topic: raw.topic };
  for (const [name, [kind, how]] of Object.entries(spec)) {
    const value = raw[name];
    if (value === undefined || (value === null && how !== "req")) {
      if (how === "req") return null;
      if (how === "def") out[name] = kind === "bool" ? false : kind === "int" ? 0 : "";
      else if (how === "opt") out[name] = null;
      continue;
    }
    if (!fits(value, kind)) return null;
    out[name] = value;
  }
  return out;
}

/// A topic by its params: one key per topic, whatever order its params came in.
export function topicKey(topic: Topic): string {
  return toJson(topic);
}

export function sameTopic(a: Topic, b: Topic): boolean {
  return topicKey(a) === topicKey(b);
}

/// A message from a UI, or why it is none.
export function parseClientMessage(
  raw: unknown,
  specs: TopicSpecs
): ClientMessage | { invalid: string } {
  if (!isObject(raw)) return { invalid: "not an object" };
  const id = raw.id;
  if (typeof id !== "number" || !Number.isInteger(id) || id < 0)
    return { invalid: "no id" };
  if (typeof raw.call === "string")
    return {
      kind: "call",
      id,
      call: raw.call,
      params: raw.params === undefined ? null : raw.params,
    };
  if ("subscribe" in raw) {
    const topic = parseTopic(raw.subscribe, specs);
    if (!topic) return { invalid: "unknown topic" };
    return raw.keyed === true
      ? { kind: "subscribe", id, subscribe: topic, keyed: true }
      : { kind: "subscribe", id, subscribe: topic };
  }
  if (raw.unsubscribe === true) return { kind: "unsubscribe", id };
  if (raw.cancel === true) return { kind: "cancel", id };
  return { invalid: "unknown message" };
}

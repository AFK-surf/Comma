import { CoreClient, CoreProvider } from "@comma/core-client";
import { TOPIC_SPECS } from "@comma/core/contract";
import { diffKeyed, type Spec } from "@comma/core-kernel";
import type { ReactNode } from "react";

type Topic = Parameters<CoreClient["subscribe"]>[0];
const fallbacks = new WeakMap<CoreClient, (core: CoreClient) => void>();

/** Sends what a scripted core does not answer (`owns`) to `core`: one slice scripted over a real core. */
export function delegateScriptedCore(scripted: CoreClient, core: CoreClient): void {
  fallbacks.get(scripted)?.(core);
}

/** A call's failure as the core sends it: its code, and the status and detail a UI may word it by. */
function errorBody(error: unknown) {
  const { code, message, status, detail } = (error ?? {}) as {
    code?: string;
    message?: string;
    status?: number;
    detail?: unknown;
  };
  return {
    code: code ?? "failed",
    message: typeof message === "string" ? message : String(error),
    ...(status === undefined ? {} : { status }),
    ...(detail === undefined ? {} : { detail }),
  };
}

const noWorkspace = { status: "ready", workspace: null } as const;

type Subscriber = {
  id: number;
  topic: Record<string, unknown>;
  keyed: boolean;
  /** What it was sent last: a keyed subscriber gets what changed since. */
  sent?: unknown;
};

/**
 * A core a UI test scripts: each topic's value comes from `values` (or `emit`; an Error fails the topic), each call
 * from `calls`. For a test of
 * how a UI shows what the core says, without the core's own behavior.
 */
export function createScriptedCore({
  values = () => undefined,
  calls = () => null,
  onSubscribe,
  onUnsubscribe,
  specs = TOPIC_SPECS,
  owns = () => true,
}: {
  /**
   * The topics (by name) and calls this script answers; the rest go to the core `delegateScriptedCore` gives it
   * (a test that scripts one slice over a real core), else see nothing.
   */
  owns?: (name: string) => boolean;
  /** Where a topic's keyed lists are (the core's own), so a change goes out as the core sends it: only what changed. */
  specs?: Record<string, Spec>;
  values?: (topic: Record<string, unknown>) => unknown;
  calls?: (name: string, params: unknown) => unknown;
  /** A UI subscribed to `topic` (the core would start keeping it current). */
  onSubscribe?: (topic: Record<string, unknown>) => void;
  onUnsubscribe?: (topic: Record<string, unknown>) => void;
} = {}) {
  const subscribers = new Set<Subscriber>();
  /** Each call the UI sent this script, in order: its name and params. */
  const sent: [name: string, params: unknown][] = [];
  /** The calls under way (by id), and those the UI let go, in order. */
  const pending = new Map<number, [name: string, params: unknown]>();
  const cancelled: [name: string, params: unknown][] = [];
  let fallback: CoreClient | null = null;
  const delegated = new Map<number, () => void>();
  const overrides = new Map<string, unknown>();
  let deliver: ((data: unknown) => void) | null = null;
  const valueOf = (topic: Record<string, unknown>) =>
    overrides.has(String(topic.topic))
      ? overrides.get(String(topic.topic))
      : (values(topic) ??
        // A core always answers the workspace a surface works in: a script that
        // does not name one has an account without a selected workspace.
        (topic.topic === "workspace" ? noWorkspace : undefined));
  const send = (subscriber: Subscriber) => {
    const value = valueOf(subscriber.topic);
    // An Error fails the subscription, as a core that cannot keep the topic does.
    if (value instanceof Error) {
      delete subscriber.sent;
      deliver?.({
        id: subscriber.id,
        error: { code: "failed", message: value.message },
      });
    } else if (value !== undefined) {
      const spec = specs[String(subscriber.topic.topic)];
      if (subscriber.keyed && spec && subscriber.sent !== undefined) {
        const delta = diffKeyed(subscriber.sent, value, spec);
        // Nothing changed: the core sends nothing.
        if (delta.length === 0) return;
        deliver?.({ id: subscriber.id, delta });
      } else deliver?.({ id: subscriber.id, value });
      subscriber.sent = structuredClone(value);
    }
  };
  const client = new CoreClient(
    (onMessage) => {
      deliver = (data) => queueMicrotask(() => onMessage(structuredClone(data)));
      return {
        post(raw) {
          const message = raw as {
            id: number;
            call?: string;
            params?: unknown;
            subscribe?: Record<string, unknown>;
            keyed?: boolean;
            unsubscribe?: boolean;
            cancel?: boolean;
          };
          const other = fallback;
          if (message.subscribe && other && !owns(String(message.subscribe.topic))) {
            const id = message.id;
            delegated.set(
              id,
              other.subscribe(
                message.subscribe as Topic,
                (value) => deliver?.({ id, value }),
                (error) =>
                  deliver?.({ id, error: { code: error.code, message: error.message } })
              )
            );
          } else if (message.unsubscribe && delegated.has(message.id)) {
            delegated.get(message.id)!();
            delegated.delete(message.id);
          } else if (message.call && other && !owns(message.call)) {
            const id = message.id;
            other.call(message.call, message.params).then(
              (ok) => deliver?.({ id, ok: ok ?? null }),
              (error: unknown) => deliver?.({ id, error: errorBody(error) })
            );
          } else if (message.subscribe) {
            const subscriber: Subscriber = {
              id: message.id,
              topic: message.subscribe,
              keyed: message.keyed === true,
            };
            subscribers.add(subscriber);
            onSubscribe?.(subscriber.topic);
            send(subscriber);
          } else if (message.unsubscribe) {
            for (const s of subscribers)
              if (s.id === message.id) {
                subscribers.delete(s);
                onUnsubscribe?.(s.topic);
              }
          } else if (message.cancel) {
            // As the core does for a call it stops: it answers `cancelled`, and its own answer is not sent.
            const call = pending.get(message.id);
            if (!call) return;
            pending.delete(message.id);
            cancelled.push(call);
            deliver?.({
              id: message.id,
              error: { code: "cancelled", message: "cancelled" },
            });
          } else if (message.call) {
            sent.push([message.call, message.params]);
            pending.set(message.id, [message.call, message.params]);
            const settle = (answer: unknown) => {
              if (!pending.delete(message.id)) return;
              deliver?.(answer);
            };
            void Promise.resolve()
              .then(() => calls(message.call!, message.params))
              .then(
                (ok) => settle({ id: message.id, ok: ok ?? null }),
                (error: unknown) => settle({ id: message.id, error: errorBody(error) })
              );
          }
        },
        close() {
          deliver = null;
        },
      };
    },
    { schedule: () => undefined }
  );
  fallbacks.set(client, (core) => (fallback = core));
  return {
    client,
    sent,
    /** The params of each call named `name` the UI sent this script, in order. */
    sentTo: (name: string) =>
      sent.filter(([n]) => n === name).map(([, params]) => params),
    /** The params of each call named `name` the UI let go before it was answered, in order. */
    cancelledTo: (name: string) =>
      cancelled.filter(([n]) => n === name).map(([, params]) => params),
    /** Sets a topic's value (by its name) and sends it to those who subscribe. */
    emit(topic: string, value: unknown) {
      overrides.set(topic, value);
      for (const subscriber of subscribers)
        if (subscriber.topic.topic === topic) send(subscriber);
    },
    /** Sends each subscriber of a topic (by its name) what `values` says of its params now. */
    changed(topic: string) {
      for (const subscriber of subscribers)
        if (subscriber.topic.topic === topic) send(subscriber);
    },
    wrap: (ui: ReactNode) => <CoreProvider client={client}>{ui}</CoreProvider>,
  };
}

/** The core's `workspace` topic for an account working in `id` (selected, so a Connector would run for it). */
export function resolvedWorkspace(id: string, name = id) {
  return {
    status: "ready" as const,
    workspace: { id, groupId: `grp_${id}`, name },
    selected: true,
  };
}

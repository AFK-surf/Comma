// What a chat message's generated UI saved on this device, per account: its own state (`state`) and its cards'
// progress (`cards`), each one JSON value, by the widget's key (the API, the workspace and the content it belongs to).
// Every window that shows the widget sees a save at once; a sign-out forgets them with the account.
//
// Bounds: a saved value is at most 32 KiB of JSON text and a key at most 1 KiB; at most 256 keys are kept, and past
// that the least recently saved go first (a lost state only starts the widget over).
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Effect } from "effect";
import type { Account } from "./account.ts";
import type { DynamicUiStateValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";

export const DYNAMIC_UI_STATE_MAX_BYTES = 32_768;
const MAX_KEY = 1024;
const MAX_KEPT = 256;
/** The keys in the order they were last saved. */
const INDEX = "dynamicUiState";
const docName = (key: string) => `dynamicUiState:${key}`;
const EMPTY: DynamicUiStateValue = { state: null, cards: null };

const encoder = new TextEncoder();

function keyOf(p: unknown): string {
  const key = (p as { key?: unknown } | null)?.key;
  if (typeof key !== "string" || !key || key.length > MAX_KEY)
    throw CoreError.invalid("key is required");
  return key;
}

export class DynamicUiStates {
  readonly #ctx: Ctx;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    const { kernel } = ctx;
    kernel.source("dynamicUiState", {
      start: () => undefined,
      stop: () => undefined,
      compute: (topic): Value => ({ ok: this.#value(topic) }),
    });
    ctx.session.onChange(() => this.#invalidate());
    kernel.calls({
      "dynamicUiState.save": {
        run: (p) =>
          Effect.sync(() => {
            const key = keyOf(p);
            const { kind, text } = p as { kind?: unknown; text?: unknown };
            if (kind !== "state" && kind !== "cards")
              throw CoreError.invalid("kind is state or cards");
            if (
              typeof text !== "string" ||
              encoder.encode(text).length > DYNAMIC_UI_STATE_MAX_BYTES
            )
              throw CoreError.invalid("text is JSON of at most 32 KiB");
            try {
              JSON.parse(text);
            } catch {
              throw CoreError.invalid("text is JSON of at most 32 KiB");
            }
            return { key, kind, text } as const;
          }).pipe(
            Effect.flatMap(({ key, kind, text }) =>
              ctx.session
                .account()
                .pipe(Effect.map((account) => this.#save(account, key, kind, text)))
            )
          ),
      },
    });
  }

  #value(topic: Topic): DynamicUiStateValue {
    const account = this.#ctx.session.current();
    if (!account || typeof topic.key !== "string") return EMPTY;
    return account.doc<DynamicUiStateValue>(docName(topic.key))?.value ?? EMPTY;
  }

  #save(account: Account, key: string, kind: "state" | "cards", text: string): null {
    const now = this.#ctx.now();
    const current = account.doc<DynamicUiStateValue>(docName(key))?.value ?? EMPTY;
    if (current[kind] === text) return null;
    if (!account.putDoc(docName(key), { ...current, [kind]: text }, now)) return null;
    // The keys in the order they were last saved: the first is the next to go.
    const order = (account.doc<string[]>(INDEX)?.value ?? []).filter((k) => k !== key);
    order.push(key);
    for (const gone of order.splice(0, Math.max(0, order.length - MAX_KEPT))) {
      account.deleteDoc(docName(gone));
      this.#invalidate(gone);
    }
    account.putDoc(INDEX, order, now);
    this.#invalidate(key);
    return null;
  }

  #invalidate(key?: string): void {
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "dynamicUiState" && (key === undefined || topic.key === key))
        store.invalidate(topic);
  }
}

// A page or a worker as a realm of a world (packages/test-utils/src/world):
// it runs on a test UI runtime, holds what other realms send it until the
// world hands it over, and tells the world what it sent and when its next
// work is due. The world's side of it is ../app-shell/support/world.ts.

import type { RealmReport, SentMessage } from "@comma/test-utils/world/world";
import type { TestUiRuntime } from "../../packages/ui/src/runtime/test/testing";

/** What the world asks of a realm; `deliver` and `settle` as in `Realm`. */
export type RealmControl = {
  settle(now: number): Promise<RealmReport>;
  deliver(from: string, id: number, detail?: unknown): Promise<void>;
  /**
   * The realms that sent it what it holds are gone (their page closed): it
   * drops what they handed it and what it would have sent them.
   */
  forget?(): void;
};

/**
 * A line between realms that does not count messages as a port does (HTTP,
 * ./realm-http.ts). The sender reports each message with a detail that names
 * the carrier; the receiver's carrier finds the message from the detail,
 * resolves once it has arrived, and returns what handing it over runs. A
 * message that can arrive only after the realm ran the ones before it (a
 * request, on a connection another request still holds) is `Awaited`: the
 * realm waits for it as it comes to run it.
 */
export type Carrier = (from: string, detail: never) => Promise<(() => void) | Awaited>;
export type Awaited = { arrived(): Promise<void>; run(): void };
const carrierOf = (detail: unknown) =>
  (detail as { carrier?: string } | null | undefined)?.carrier;
const lineOf = (detail: unknown) =>
  (detail as { line?: string } | null | undefined)?.line;
// A realm's messages to a peer are counted on each line of its own (a
// window's, each port's): a line delivers in the order it was sent, but two
// lines may deliver in either order.
const lineKey = (peer: string, line: string | undefined) =>
  line === undefined ? peer : `${peer}\u0000${line}`;

/** A realm's requests to `origin` go to the realm `peer` (./realm-http.ts). */
export type HttpRoute = {
  peer: string;
  origin: string;
  /** The proof's perturbation: each arrival is noticed up to this many real ms late. */
  delayMs: number;
  /** The page the route is of, counted in the test: its requests' names are its own. */
  epoch?: number;
};

type Inbox = {
  arrived: (() => void)[];
  count: number;
  waiting: Map<number, () => void>;
};

/** A source of `message` events and a `postMessage`: a Worker, or a worker's own global. */
type Endpoint = {
  addEventListener(type: string, listener: (event: Event) => void): void;
  postMessage(message: unknown, transfer?: Transferable[]): void;
};

const label = (message: unknown) => {
  const text = typeof message === "string" ? message : JSON.stringify(message);
  return (text ?? String(message)).slice(0, 60);
};

/** A control message of the world itself, on the wire beside the realms' own messages. */
export type WorldCall =
  | { call: number; op: "settle"; now: number }
  | { call: number; op: "deliver"; from: string; id: number; detail?: unknown }
  | { call: number; op: "http"; route: HttpRoute };
export type WorldReply = { reply: number; report?: RealmReport; error?: string };
/** A worker's first message: its realm is set up, before its own modules run. */
export type WorldReady = { ready: true };
export type WorldMessage = WorldCall | WorldReply | WorldReady;
export const worldMessage = (data: unknown) =>
  (data as { commaWorld?: WorldMessage } | null | undefined)?.commaWorld;

export function createRealm(
  runtime: TestUiRuntime,
  {
    advance,
    rest,
    due,
  }: {
    /** Runs `ms` of the realm's time. */
    advance(ms: number): Promise<void>;
    /** Runs what is due now, to rest. */
    rest(): Promise<void>;
    /** The next time something of the realm is due, when the runtime's own answer is not all of it. */
    due?(): number | null;
  }
) {
  let sent: SentMessage[] = [];
  const sentTo = new Map<string, number>();
  const carriers = new Map<string, Carrier>();
  const send = (to: string, what: string, detail?: unknown) => {
    const key = lineKey(to, lineOf(detail));
    const id = (sentTo.get(key) ?? 0) + 1;
    sentTo.set(key, id);
    sent.push(
      detail === undefined ? { to, id, label: what } : { to, id, label: what, detail }
    );
  };
  const inboxes = new Map<string, Inbox>();
  const inbox = (from: string) => {
    let box = inboxes.get(from);
    if (!box) {
      box = { arrived: [], count: 0, waiting: new Map() };
      inboxes.set(from, box);
    }
    return box;
  };

  // What the world handed over since the realm last ran, in that order.
  let handed: ((() => void) | Awaited)[] = [];

  const control: RealmControl = {
    async settle(now) {
      // The realm's time first: what was handed over runs at the world's
      // time, not at the time the realm last ran.
      const ms = now - runtime.elapsed();
      if (ms > 0) await advance(ms);
      const runs = handed;
      handed = [];
      for (const run of runs) {
        if (typeof run === "function") {
          runtime.task.post(run);
          continue;
        }
        // What ran before it may be what lets it arrive.
        await rest();
        await run.arrived();
        runtime.task.post(() => run.run());
      }
      await rest();
      const report = { nextDue: due ? due() : runtime.nextDue(), sent };
      sent = [];
      return report;
    },
    forget() {
      handed = [];
      sent = [];
      sentTo.clear();
      inboxes.clear();
    },
    async deliver(from, id, detail) {
      const carrier = carrierOf(detail);
      if (carrier !== undefined) {
        const carry = carriers.get(carrier);
        if (!carry) throw new Error(`The realm has no ${carrier} line to ${from}.`);
        handed.push(await carry(from, detail as never));
        return;
      }
      const box = inbox(lineKey(from, lineOf(detail)));
      // The message is on its way: however long it takes, it is the next of
      // its sender's to run here.
      if (box.count < id)
        await new Promise<void>((resolve) => box.waiting.set(id, resolve));
      const run = box.arrived.shift();
      if (!run) throw new Error(`Message ${id} from ${from} was handed over twice.`);
      handed.push(run);
    },
  };

  return {
    control,
    /** Reports a message of a carrier's line: the next the realm sends `to`. */
    send,
    /** Makes `carry` the receiving end of the lines of `carrier`. */
    carry(carrier: string, carry: Carrier) {
      carriers.set(carrier, carry);
    },
    /**
     * Makes `endpoint` the realm's line to the realm `peer`: what the realm
     * posts on it is reported to the world, and what arrives on it is held
     * until the world hands it over. `onWorld` receives the world's own
     * messages on the line. Returns the endpoint's unrouted `postMessage`.
     */
    route(
      peer: string,
      endpoint: Endpoint & { onmessage: ((event: MessageEvent) => unknown) | null },
      onWorld: (message: WorldMessage) => void,
      {
        line,
        received = (event) => event,
        ran,
      }: {
        /** The line's name when the realm has more than one to `peer`. */
        line?: string;
        /** The event the realm's code receives for one that arrived (its ports routed). */
        received?: (event: MessageEvent) => MessageEvent;
        /** Sees each message of the peer as the realm runs it. */
        ran?: (data: unknown) => void;
      } = {}
    ) {
      const listeners = new Set<EventListenerOrEventListenerObject>();
      let handler: ((event: MessageEvent) => unknown) | null = null;
      const add = endpoint.addEventListener.bind(endpoint);
      const post = endpoint.postMessage.bind(endpoint);
      add("message", (event) => {
        const arrivedEvent = event as MessageEvent;
        const world = worldMessage(arrivedEvent.data);
        event.stopImmediatePropagation();
        if (world) {
          onWorld(world);
          return;
        }
        const box = inbox(lineKey(peer, line));
        box.count += 1;
        box.arrived.push(() => {
          const message = received(arrivedEvent);
          ran?.(message.data);
          handler?.call(endpoint, message);
          for (const listener of listeners) {
            if (typeof listener === "function") listener.call(endpoint, message);
            else listener.handleEvent(message);
          }
        });
        const waiting = box.waiting.get(box.count);
        box.waiting.delete(box.count);
        waiting?.();
      });
      endpoint.addEventListener = ((
        type: string,
        listener: EventListenerOrEventListenerObject | null,
        options?: unknown
      ) => {
        if (type !== "message")
          return (add as (...args: unknown[]) => void)(type, listener, options);
        if (listener) listeners.add(listener);
      }) as typeof endpoint.addEventListener;
      Object.defineProperty(endpoint, "onmessage", {
        configurable: true,
        get: () => handler,
        set(next: ((event: MessageEvent) => unknown) | null) {
          handler = next;
        },
      });
      endpoint.postMessage = ((message: unknown, transfer?: Transferable[]) => {
        send(peer, label(message), line === undefined ? undefined : { line });
        post(message, transfer);
      }) as typeof endpoint.postMessage;
      return post;
    },
  };
}

export type RealmOfWorld = ReturnType<typeof createRealm>;

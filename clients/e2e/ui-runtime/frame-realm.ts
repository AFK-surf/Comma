// Runs first in a sandboxed frame of the test build: the dynamic UI runtime's
// document as the test server gives it to a page (vitest.config.ts,
// servedDynamicUi), this module inlined before the runtime's own script. The
// frame has an origin of its own (opaque), so its page cannot reach into it:
// the frame is a realm of the page's world (./realm.ts) beside the page and
// its workers. It runs on a UI runtime of its own; what the page posts it,
// on its window or on a port the page sent it, is held until the world hands
// it over, each line in the order it was sent; what it posts the page is
// reported to the world. Its workers (blob scripts) are realms too: their
// scripts start with the worker realm's modules (COMMA_FRAME_WORKER_PRELUDE).

import { testEpoch } from "@comma/test-utils/test-epoch";
import {
  createTestUiRuntime,
  installTestUiHost,
  realHost,
} from "../../packages/ui/src/runtime/test/testing";
import {
  derivedSeed,
  installSeededRandom,
  workerSeedParameter,
} from "../app-shell/support/random";
import {
  createRealm,
  type WorldCall,
  type WorldMessage,
  type WorldReply,
} from "./realm";
import { routePlatform } from "./realm-platform";
import { frameHello, workerPeerParameter, workerRealmParameter } from "./realm-names";

declare const COMMA_FRAME_WORKER_PRELUDE: string;

/** What the page's side sends a frame before anything else: the frame's name in the world, and its seed. */
export type FrameNamed = { frame: string; seed: number };
/** A message the page posted a frame with ports of its own: each port is a line of its own (`lines`). */
export type FrameEnvelope = { commaFrameLines: string[]; data: unknown };
/** What the frame tells its page when trusted input reached it (the page's input waits for it). */
export type FrameInput = { frameInput: string };

const frameMs = 16;
const realParent = window.parent;
const rawPost = (message: unknown, transfer: Transferable[] = []) =>
  realParent.postMessage(message, "*", transfer);

installTestUiHost();
const runtime = createTestUiRuntime({ seed: 0, start: testEpoch, layout: true });
runtime.install();
installSeededRandom(window, 0);

// The frame's time moves as a page's does: frame by frame.
const advanceBy = async (ms: number) => {
  await runtime.render();
  for (const end = runtime.elapsed() + ms; runtime.elapsed() < end; ) {
    const now = runtime.elapsed();
    const next = (Math.floor(now / frameMs) + 1) * frameMs;
    if (next > end) {
      await runtime.advance(end - now);
      break;
    }
    await runtime.advanceFrames(1);
    if (runtime.elapsed() === now) await runtime.advanceFrames(1);
  }
  await runtime.render();
};
const realm = createRealm(runtime, {
  advance: advanceBy,
  rest: () => runtime.render(),
});
const outside: string[] = [];
routePlatform(runtime, (what) => outside.push(what));

let name = "frame";
let seed = 0;

// --- the frame's lines to its page -------------------------------------------

type Endpoint = Parameters<typeof realm.route>[1];
const rawAdd = window.addEventListener.bind(window);
const rawRemove = window.removeEventListener.bind(window);
const windowLine = {
  addEventListener: rawAdd,
  postMessage: (message: unknown, transfer?: Transferable[]) =>
    rawPost(message, transfer),
  onmessage: null,
} as unknown as Endpoint;

// A port the page sent: a line of its own to the page.
const routePort = (port: MessagePort, line: string) => {
  realm.route("page", port as unknown as Endpoint, () => {}, { line });
  return port;
};

// The frame's parent as its code sees it: a window whose messages are the
// line's. A message from the page names it as its source, as the browser
// names the parent.
const parentWindow = {
  postMessage(message: unknown, _origin?: string, transfer?: Transferable[]) {
    if (transfer?.length)
      throw new Error("A frame of the test build sends its page no ports.");
    // oxlint-disable-next-line unicorn/require-post-message-target-origin -- the line is the page's window, the origin its own.
    windowLine.postMessage(message);
  },
};
realm.route("page", windowLine, (message) => onWorld(message), {
  received(event) {
    const envelope = event.data as FrameEnvelope | null;
    const lines = Array.isArray(envelope?.commaFrameLines)
      ? envelope.commaFrameLines
      : [];
    // What the frame's code reads of a message event: not one the browser made.
    return {
      type: "message",
      data: lines.length > 0 ? envelope!.data : event.data,
      origin: event.origin,
      lastEventId: event.lastEventId,
      source: event.source === realParent ? parentWindow : event.source,
      ports: event.ports.map((port, index) => routePort(port, lines[index]!)),
      isTrusted: true,
    } as unknown as MessageEvent;
  },
});
// The frame's code listens on its window and posts to its parent: both are the line.
window.addEventListener = ((
  type: string,
  listener: EventListener,
  options?: unknown
) =>
  type === "message"
    ? windowLine.addEventListener(type, listener)
    : rawAdd(
        type,
        listener,
        options as AddEventListenerOptions
      )) as typeof window.addEventListener;
window.removeEventListener = ((
  type: string,
  listener: EventListener,
  options?: unknown
) =>
  type === "message"
    ? undefined
    : rawRemove(
        type,
        listener,
        options as EventListenerOptions
      )) as typeof window.removeEventListener;
Object.defineProperty(window, "onmessage", {
  configurable: true,
  get: () => windowLine.onmessage,
  set: (handler) => {
    // oxlint-disable-next-line unicorn/prefer-add-event-listener -- the frame's own `onmessage`, kept on its line.
    windowLine.onmessage = handler;
  },
});
Object.defineProperty(window, "parent", { configurable: true, value: parentWindow });

// Trusted input reached the frame: the page's input waits for it.
for (const type of [
  "pointermove",
  "pointerdown",
  "pointerup",
  "pointerout",
  "keydown",
  "keyup",
  "input",
  "wheel",
])
  rawAdd(type, () => rawPost({ commaWorld: { frameInput: type } }), true);

// --- the frame's workers ----------------------------------------------------

const HostBlob = Blob;
// The browser's own: the runtime's refuses a worker it does not route.
const HostWorker = realHost().Worker!;
const hostCreateUrl = URL.createObjectURL.bind(URL);
const blobParts = new WeakMap<Blob, BlobPart[]>();
const blobOfUrl = new Map<string, Blob>();
window.Blob = class extends HostBlob {
  constructor(parts?: BlobPart[], options?: BlobPropertyBag) {
    super(parts, options);
    blobParts.set(this, parts ?? []);
  }
};
URL.createObjectURL = (object: Blob | MediaSource) => {
  const url = hostCreateUrl(object);
  if (object instanceof HostBlob) blobOfUrl.set(url, object);
  return url;
};

type WorkerControl = {
  call(body: Omit<WorldCall, "call">): Promise<WorldReply>;
};
const workers = new Map<string, WorkerControl>();
window.Worker = function (url: string | URL, options?: WorkerOptions) {
  const blob = blobOfUrl.get(String(url));
  const parts = blob && blobParts.get(blob);
  if (!parts)
    throw new Error(
      `A frame's worker runs from a script blob of the frame: ${String(url)}`
    );
  const workerName = `${name} worker ${workers.size + 1}`;
  const script = hostCreateUrl(
    new HostBlob([COMMA_FRAME_WORKER_PRELUDE, ";\n", ...parts], {
      type: "text/javascript",
    })
  );
  const hash = new URLSearchParams({
    [workerSeedParameter]: String(derivedSeed(seed, workers.size + 1)),
    [workerRealmParameter]: workerName,
    [workerPeerParameter]: name,
  }).toString();
  const worker = new HostWorker(`${script}#${hash}`, options);
  let calls = 0;
  const replies = new Map<number, (reply: WorldReply) => void>();
  const post = realm.route(workerName, worker as unknown as Endpoint, (message) => {
    if (!("reply" in message)) return;
    replies.get(message.reply)?.(message);
    replies.delete(message.reply);
  });
  // A worker the frame stopped rests for good: what the world asks it, it
  // answers at once with nothing due and nothing sent.
  let terminated = false;
  const terminate = worker.terminate.bind(worker);
  worker.terminate = () => {
    terminated = true;
    terminate();
    for (const [id, reply] of replies)
      reply({ reply: id, report: { nextDue: null, sent: [] } });
    replies.clear();
  };
  worker.addEventListener("error", (event) => {
    const error = `${event.message || "the worker failed to load"}`;
    for (const [id, reply] of replies) reply({ reply: id, error });
    replies.clear();
  });
  workers.set(workerName, {
    call: (body) =>
      new Promise<WorldReply>((resolve) => {
        if (terminated) {
          resolve({ reply: 0, report: { nextDue: null, sent: [] } });
          return;
        }
        calls += 1;
        replies.set(calls, resolve);
        post({ commaWorld: { call: calls, ...body } as WorldCall });
      }),
  });
  return worker;
} as unknown as typeof Worker;

// --- the world's calls --------------------------------------------------------

type FrameCall = WorldCall & { realm?: string };

function onWorld(message: WorldMessage | FrameNamed) {
  if ("frame" in message) {
    name = message.frame;
    seed = message.seed;
    window.name = name;
    return;
  }
  if (!("call" in message)) return;
  const call = message as FrameCall;
  const answer = (reply: Omit<WorldReply, "reply">) =>
    rawPost({ commaWorld: { ...reply, reply: call.call } });
  let done: Promise<Omit<WorldReply, "reply">>;
  if (call.realm && call.realm !== name) {
    const worker = workers.get(call.realm);
    done = worker
      ? worker
          .call(
            Object.fromEntries(
              Object.entries(call).filter(([key]) => key !== "call" && key !== "realm")
            ) as Omit<WorldCall, "call">
          )
          .then(({ reply: _reply, ...rest }) => rest)
      : Promise.reject(new Error(`${name} has no ${call.realm}.`));
  } else if (call.op === "settle")
    done = realm.control.settle(call.now).then((report) => {
      const problems = [...outside.splice(0), ...runtime.violations()];
      if (problems.length > 0)
        throw new Error(
          `did what its runtime does not control:\n${problems.join("\n")}`
        );
      return { report, workers: [...workers.keys()] } as Omit<WorldReply, "reply">;
    });
  else if (call.op === "deliver")
    done = realm.control.deliver(call.from, call.id, call.detail).then(() => ({}));
  else done = Promise.resolve({});
  done.then(answer, (error: unknown) => answer({ error: String(error) }));
}

rawPost({ commaWorld: { frameHello } });

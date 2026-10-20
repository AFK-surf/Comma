// A core on the web: every tab has a dedicated worker of its own, and one of them runs the core: the one holding the
// Web Lock `<name>`, as the core's databases are SQLite on OPFS, whose access handles only one worker can hold. The
// other tabs' workers relay their page's messages to it over a BroadcastChannel, and what it says back; when the tab
// running the core goes, the lock goes to another worker, which starts the core from the same databases, and every
// page subscribes again (`rejoin`). A worker of an older build retires when a newer one starts (its pages reload), so
// two builds never run two cores on the same storage. No Effect here: the core started is whatever `start` gives.
/* oxlint-disable unicorn/require-post-message-target-origin, unicorn/prefer-add-event-listener -- MessagePort, Worker and BroadcastChannel take no target origin, and `onmessage` is what starts a port. */

/// What runs the core, as the worker uses it.
export interface WorkerCore {
  connect(): number;
  receive(client: number, message: unknown): void;
  disconnect(client: number): void;
}

export interface RelayOptions {
  /// The lock's and channels' name: one per app.
  name: string;
  /// This build (a number that grows with each build).
  build: number;
  /// Starts the core in this worker: `emit` sends to a client, `fatal` ends this worker (another takes over).
  start(
    emit: (client: number, message: unknown) => void,
    fatal: (reason: string) => void
  ): Promise<WorkerCore>;
}

interface Port {
  postMessage(message: unknown): void;
  onmessage: ((event: MessageEvent) => void) | null;
  close(): void;
  addEventListener(type: "error", listener: (event: ErrorEvent) => void): void;
  addEventListener(
    type: "unhandledrejection",
    listener: (event: PromiseRejectionEvent) => void
  ): void;
}

/// What the workers say to each other: a worker started (`hello`); who runs the core (`leader`, to one or all); a
/// page's message to the core (`up`), and the core's to a page (`down`).
type Relayed =
  | { hello: string }
  | { leader: string; to?: string }
  | { from: string; to: string; up: unknown }
  | { from: string; to: string; down: unknown };

/// Runs this worker as one of the tabs' workers. `scope` is the worker's global scope.
export function runCoreWorker(
  options: RelayOptions,
  scope: Port = globalThis as unknown as Port
): void {
  // Names this tab's lock among the browser's other tabs; it never reaches the core.
  // @effect-diagnostics-next-line cryptoRandomUUID:off
  const tab = crypto.randomUUID();
  const coreLock = options.name;
  const tabLock = (id: string) => `${options.name}-tab-${id}`;
  const relay = new BroadcastChannel(`${options.name}-${options.build}`);
  const builds = new BroadcastChannel(`${options.name}-builds`);

  let core: WorkerCore | null = null;
  let dead = false;
  /// The worker running the core: this one once it holds the lock; null until it is known.
  let leader: string | null = null;
  /// What this page said before the core was known, in order.
  let queued: unknown[] = [];
  /// This page's client of the core when it runs here.
  let mine: number | null = null;
  /// The other tabs' clients of the core running here, by their worker.
  const remotes = new Map<string, number>();
  const clients = new Map<number, (message: unknown) => void>();

  const toPage = (message: unknown) => {
    try {
      scope.postMessage(message);
    } catch {
      // The page is gone; this worker goes with it.
    }
  };

  const emit = (client: number, message: unknown) => {
    const send = clients.get(client);
    if (!send) return;
    try {
      send(message);
    } catch {
      // A port that cannot take messages any more is gone; not from inside emit (the core is in the middle of something).
      queueMicrotask(() => gone(client));
    }
  };

  const gone = (client: number) => {
    if (!clients.delete(client)) return;
    for (const [id, c] of remotes) if (c === client) remotes.delete(id);
    if (mine === client) mine = null;
    guard(() => core?.disconnect(client));
  };

  /// This core is finished: this page starts a new worker, and this one ends (its lock goes to another tab's).
  const fatal = (reason: string) => {
    if (dead) return;
    dead = true;
    toPage({ fatal: reason });
    relay.close();
    builds.close();
    scope.close();
  };

  /// An error the core survives, handed to this page for error tracking (a worker's console is out of its reach).
  const fault = (error: unknown) => {
    const body =
      error instanceof Error
        ? {
            name: error.name,
            message: error.message,
            ...(error.stack ? { stack: error.stack } : {}),
          }
        : { name: "Error", message: String(error) };
    toPage({ fault: body });
  };

  const guard = (run: () => void) => {
    try {
      run();
    } catch (error) {
      fault(error);
    }
  };

  const retire = () => {
    if (dead) return;
    dead = true;
    toPage({ retired: true });
    builds.close();
    relay.close();
    scope.close();
  };

  builds.onmessage = (event: MessageEvent) => {
    const other = (event.data as { built?: unknown } | null)?.built;
    if (typeof other !== "number" || other === options.build) return;
    if (other > options.build) retire();
    // An older one started after this: it hears of this one and retires.
    else builds.postMessage({ built: options.build });
  };
  builds.postMessage({ built: options.build });

  /// A message of this page to the core running here.
  const local = (data: unknown) => {
    const running = core!;
    if (typeof data === "object" && data !== null && "bye" in data) {
      if (mine !== null) gone(mine);
      return;
    }
    guard(() => {
      if (mine === null) {
        mine = running.connect();
        clients.set(mine, toPage);
      }
      running.receive(mine, data);
    });
  };

  scope.onmessage = (event) => {
    const data: unknown = event.data;
    if (dead) return;
    if (core !== null) return local(data);
    if (leader === null) {
      queued.push(data);
      return;
    }
    relay.postMessage({ from: tab, to: leader, up: data } satisfies Relayed);
  };

  /// The core runs in worker `id`: what was queued goes to it; when it is another than before, the page subscribes anew.
  const follow = (id: string) => {
    if (core !== null || id === leader) return;
    const before = leader;
    leader = id;
    if (before !== null) {
      queued = [];
      toPage({ rejoin: true });
      return;
    }
    const waiting = queued;
    queued = [];
    for (const message of waiting)
      relay.postMessage({ from: tab, to: id, up: message } satisfies Relayed);
  };

  let ready: Promise<WorkerCore> | null = null;

  /// A message of another tab's page to the core running here.
  const fromTab = (id: string, message: unknown) => {
    void ready?.then((running) => {
      if (dead) return;
      let client = remotes.get(id);
      if (typeof message === "object" && message !== null && "bye" in message) {
        if (client !== undefined) gone(client);
        return;
      }
      guard(() => {
        if (client === undefined) {
          client = running.connect();
          remotes.set(id, client);
          clients.set(client, (out) =>
            relay.postMessage({ from: tab, to: id, down: out } satisfies Relayed)
          );
          // That tab's worker holds its own lock for as long as it lives: granted here once it is gone.
          const c = client;
          void navigator.locks.request(tabLock(id), () => {
            if (remotes.get(id) === c) gone(c);
          });
        }
        running.receive(client, message);
      });
    });
  };

  relay.onmessage = (event: MessageEvent) => {
    const data = event.data as Relayed;
    if (dead || typeof data !== "object" || data === null) return;
    if ("hello" in data) {
      if (core !== null)
        relay.postMessage({ leader: tab, to: data.hello } satisfies Relayed);
      return;
    }
    if ("leader" in data) {
      if (data.to !== undefined && data.to !== tab) return;
      follow(data.leader);
      return;
    }
    if (data.to !== tab) return;
    if ("up" in data) {
      if (core !== null) fromTab(data.from, data.up);
    } else if (core === null && data.from === leader) {
      toPage(data.down);
    }
  };

  // This worker's own lock, held as long as it lives (the worker running the core hears when it is gone).
  void navigator.locks.request(tabLock(tab), () => new Promise<void>(() => {}));
  relay.postMessage({ hello: tab } satisfies Relayed);
  // Runs the core once the lock is this worker's: at once when no other tab runs one, else when it goes.
  void navigator.locks.request(coreLock, async () => {
    if (dead) return;
    const followed = leader !== null;
    ready = options.start(emit, fatal);
    ready.catch((error: unknown) => fatal(`the core did not start: ${String(error)}`));
    const running = await ready;
    core = running;
    leader = tab;
    relay.postMessage({ leader: tab } satisfies Relayed);
    if (followed) {
      queued = [];
      toPage({ rejoin: true });
    } else {
      const waiting = queued;
      queued = [];
      for (const message of waiting) local(message);
    }
    await new Promise<void>(() => {});
  });

  scope.addEventListener("error", (event) => {
    fault(event.error ?? event.message);
    event.preventDefault();
  });
  scope.addEventListener("unhandledrejection", (event) => {
    fault(event.reason);
    event.preventDefault();
  });
}

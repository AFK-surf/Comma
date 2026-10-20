// Stations for core tests: endpoints in memory (`@comma/mesh/testing`), each served as a station's direct connection
// is (`comma/mesh/1`), with the admin API parts a test needs. A member credential here is JSON (`fakeCredential`):
// the station admits it for its workspace and the device it names, until it expires, as a real station checks the
// control plane's signed one.
import { HostError } from "@comma/core-kernel";
import {
  MESH_ALPN,
  MeshError,
  serveMesh,
  type MeshReply,
  type ServedRequest,
} from "@comma/mesh";
import { MemoryMesh } from "@comma/mesh/testing";
import { Effect } from "effect";
import type { StationToolsAccess } from "../contract.ts";
import type { StationMeshPorts } from "../host.ts";
import { meshStationLinks } from "../hosts/mesh.ts";

type Claims = { ws: string; device: string; role: string; exp: number };

/** A member credential as a fake station takes it. */
export function fakeCredential(claims: Claims): string {
  return JSON.stringify(claims);
}

/** A chat entry as a fake station keeps it. */
export type Entry = {
  n: number;
  kind: string;
  target: number | null;
  ts: string;
  authorKind: string;
  author: string;
  authorName: string;
  text: string;
  attachments: unknown[];
  quotes: { ts?: string }[];
  at: number;
  card?: unknown;
  ending?: string;
};

type Handler = (
  request: ServedRequest<Claims>,
  body: unknown
) => MeshReply | Promise<MeshReply>;

const reply = (status: number, value: unknown): MeshReply => ({
  status,
  headers: [["content-type", "application/json"]],
  body: new TextEncoder().encode(JSON.stringify(value)),
});

/** A station's event stream as a test feeds it: each `say` is one event; `end` ends it. */
class EventFeed {
  readonly #queue: (Uint8Array | null)[] = [];
  #wake: (() => void) | null = null;
  ended = false;

  say(name: string, data: unknown): void {
    this.#push(
      new TextEncoder().encode(`event: ${name}\ndata: ${JSON.stringify(data)}\n\n`)
    );
  }

  end(): void {
    this.#push(null);
  }

  #push(piece: Uint8Array | null): void {
    this.#queue.push(piece);
    this.#wake?.();
    this.#wake = null;
  }

  async *body(signal: AbortSignal): AsyncIterable<Uint8Array> {
    yield new TextEncoder().encode("retry: 3000\n\n");
    for (;;) {
      while (this.#queue.length === 0) {
        if (signal.aborted) return;
        await new Promise<void>((wake) => (this.#wake = wake));
      }
      const piece = this.#queue.shift()!;
      if (piece === null) {
        this.ended = true;
        return;
      }
      yield piece;
    }
  }
}

export class FakeStation {
  readonly id: string;
  readonly workspace: string;
  /** The workspace id it takes member credentials for: its own, until a test has the control plane tell it another. */
  takes: string;
  access: StationToolsAccess = "off";
  /** What `GET /chats` answers (rows as the station has them). */
  chats: unknown[] = [];
  /** What `GET /jobs` answers. */
  jobs: unknown[] = [];
  /** The runtimes its profiles offer (`GET /overview`). */
  runtimes: string[] = ["claude"];
  /** The profiles `GET /overview` says, when a test gives them (else one per runtime). */
  profiles: unknown[] | undefined;
  /** What each new chat was asked with (`POST /sessions`). */
  readonly sessions: unknown[] = [];
  /** Files put on it, by name, and sessions whose chat it made. */
  readonly uploads: string[] = [];
  readonly made: string[] = [];
  /** Event streams opened, in order: the last is the open one. */
  readonly feeds: EventFeed[] = [];
  /** Writes to a chat (`/threads/:id/...`): a message, a dismissal, a closed card; answered `{n}` or `{}`. */
  readonly writes: { method: string; path: string; body: unknown; key?: string }[] = [];
  #nextThread = 100;
  #nextN = 1_000;
  /** Requests it was asked, `METHOD path`. */
  readonly asked: string[] = [];
  /** Credentials it admitted, in order. */
  readonly admitted: Claims[] = [];
  readonly #routes = new Map<string, Handler>();

  constructor(id: string, workspace: string) {
    this.id = id;
    this.workspace = workspace;
    this.takes = workspace;
    this.on("GET", "/tools/access", () => reply(200, { access: this.access }));
    this.on("PUT", "/tools/access", (request, body) => {
      if (request.principal.role === "viewer")
        return reply(403, { error: "read-only members cannot change this station" });
      this.access = (body as { access: StationToolsAccess }).access;
      return reply(200, { access: this.access });
    });
    this.on("GET", "/chats", () => reply(200, this.chats));
    this.on("GET", "/jobs", () => reply(200, this.jobs));
    this.on("GET", "/overview", () =>
      reply(200, {
        profiles:
          this.profiles ?? this.runtimes.map((runtime) => ({ id: runtime, runtime })),
      })
    );
    this.on("POST", "/uploads", (request) => {
      const name =
        new URLSearchParams(request.path.split("?")[1] ?? "").get("name") ?? "file";
      this.uploads.push(name);
      return reply(200, { name, path: `/uploads/${name}`, size: 3 });
    });
    this.on("POST", "/threads", (_request, body) => {
      const made = this.#nextThread++;
      this.threads.set(made, { title: null, entries: [], read: 0 });
      this.made.push((body as { session: string }).session);
      return reply(200, { id: made, title: null, last: 0, read: 0 });
    });
    this.on("POST", "/sessions", (request, body) => {
      const key = request.headers.find(([name]) => name === "idempotency-key")?.[1];
      // A write sent again with its key is answered as the first was.
      const again = key ? this.#answered.get(`/sessions\t${key}`) : undefined;
      if (again) return again;
      this.sessions.push(body);
      const thread = this.#nextThread++;
      const asked = body as { runtime: string; title?: string };
      this.threads.set(thread, { title: asked.title ?? null, entries: [], read: 0 });
      const answer = reply(200, {
        key: `s_${asked.runtime}_${thread}`,
        thread: { id: thread },
      });
      if (key) this.#answered.set(`/sessions\t${key}`, answer);
      return answer;
    });
  }

  /** A write to a chat: noted, with the write's key. */
  #threadRoute(method: string, path: string, query: string): Handler | undefined {
    const at =
      /^\/threads\/(\d+)(?:\/(messages|dismissed|closed-card|read|entries|status|labels))?$/.exec(
        path
      );
    if (!at) return undefined;
    const thread = Number(at[1]);
    const action = at[2];
    if (method === "GET" && action === undefined)
      return () =>
        this.threads.has(thread)
          ? reply(200, this.#view(thread))
          : reply(404, { error: `unknown thread ${thread}` });
    if (method === "GET" && action === "entries")
      return () => {
        const chat = this.threads.get(thread);
        if (!chat) return reply(404, { error: `unknown thread ${thread}` });
        const q = new URLSearchParams(query);
        const all = chat.entries.toSorted((a, b) => a.n - b.n);
        const last = all.at(-1)?.n ?? 0;
        const after = q.get("after");
        const before = q.get("before");
        const limit = Number(q.get("limit") ?? 50) || 50;
        const picked =
          after !== null
            ? all.filter((e) => e.n > Number(after))
            : all.filter((e) => before === null || e.n < Number(before)).slice(-limit);
        return reply(200, { last, entries: picked });
      };
    if (method === "PUT" && action === "read")
      return (_request, body) => {
        const n = (body as { n: number }).n;
        const chat = this.threads.get(thread);
        if (chat) chat.read = Math.max(chat.read, n);
        this.writes.push({ method, path, body });
        return reply(200, { thread, n: chat?.read ?? n });
      };
    if (action === undefined) return undefined;
    return (request, body) => {
      const key = request.headers.find(([name]) => name === "idempotency-key")?.[1];
      // A write sent again with its key is answered as the first was.
      const again = key ? this.#answered.get(`${path}\t${key}`) : undefined;
      if (again) return again;
      this.writes.push({ method, path, body, ...(key ? { key } : {}) });
      let answer = reply(200, {});
      if (action === "messages") {
        const n = this.#nextN++;
        const chat = this.threads.get(thread);
        const posted = body as { text: string; attachments?: unknown[] };
        if (chat) {
          const entry = this.entry(n, "person", posted.text, {
            author: this.viewer,
            attachments: posted.attachments ?? [],
          });
          chat.entries.push(entry);
          if (this.sayEntries) this.feed?.say("thread", { thread, entries: [entry] });
        }
        answer = reply(200, { n });
      }
      if (action === "labels") {
        const asked = (body as { labels: string[] }).labels;
        answer = reply(200, { thread, labels: [...new Set(asked)].toSorted() });
      }
      if (action === "status") {
        const asked = (body as { status: string }).status;
        answer = reply(200, {
          thread,
          status: asked === "in_progress" ? "needs_review" : asked,
        });
      }
      if (key) this.#answered.set(`${path}\t${key}`, answer);
      return answer;
    };
  }

  /** The station's chats by thread: their entries, and where the viewer read to. */
  readonly threads = new Map<
    number,
    { title: string | null; entries: Entry[]; read: number }
  >();
  /** The viewer's email, as the station writes it on their messages. */
  viewer = "user-1@example.test";
  /** Whether a message posted is said on the event stream (as a station does). */
  sayEntries = true;
  readonly #answered = new Map<string, MeshReply>();

  /** An entry as the station keeps it. */
  entry(
    n: number,
    authorKind: string,
    text: string,
    extra: Partial<Entry> = {}
  ): Entry {
    return {
      n,
      kind: "message",
      target: null,
      ts: `ts${n}`,
      authorKind,
      author: authorKind === "agent" ? "s_1" : this.viewer,
      authorName: authorKind === "agent" ? "Opus" : "Ada",
      text,
      attachments: [],
      quotes: [],
      at: n * 1_000,
      ...extra,
    };
  }

  #view(id: number) {
    const chat = this.threads.get(id)!;
    const last = Math.max(0, ...chat.entries.map((e) => e.n));
    return { id, title: chat.title, last, read: chat.read };
  }

  /** The event stream open now. */
  get feed(): EventFeed | undefined {
    return this.feeds.findLast((feed) => !feed.ended);
  }

  /** Answers `METHOD path` (the path without its query). */
  on(method: string, path: string, handler: Handler): this {
    this.#routes.set(`${method} ${path}`, handler);
    return this;
  }

  async handle(request: ServedRequest<Claims>): Promise<MeshReply> {
    const key = `${request.method} ${request.path.split("?")[0]}`;
    this.asked.push(`${request.method} ${request.path}`);
    if (key === "GET /events") {
      const feed = new EventFeed();
      this.feeds.push(feed);
      return {
        status: 200,
        headers: [["content-type", "text/event-stream"]],
        body: feed.body(request.signal),
      };
    }
    const chunks: Uint8Array[] = [];
    for await (const chunk of request.body) chunks.push(chunk);
    const text = new TextDecoder().decode(
      chunks.length === 1 ? chunks[0] : Buffer.concat(chunks)
    );
    const [bare, query = ""] = request.path.split("?");
    const handler =
      this.#routes.get(key) ?? this.#threadRoute(request.method, bare!, query);
    if (!handler) return reply(404, { error: `no route ${key}` });
    const json = request.headers.some(
      ([name, value]) => name === "content-type" && value === "application/json"
    );
    return handler(request, text === "" ? undefined : json ? JSON.parse(text) : text);
  }
}

/** A relay socket the core opened on a fake endpoint. */
export interface FakeRelaySocket {
  url: string;
  ticket: string;
  open: boolean;
  drop(): void;
}

/** The mesh a test's core binds its endpoint on, with the stations on it. */
export class FakeStations {
  readonly mesh = new MemoryMesh();
  /** Each endpoint the core bound: its id and the relays it was given. */
  readonly bound: { id: string; relays: readonly string[] }[] = [];
  /** Whether the endpoint is bound now. */
  open = false;
  /** The endpoint is reached through Salix too, as one on a station's addon is: the core opens relay sockets. */
  salix = false;
  /** Each relay socket the core opened, by the ticket it gave; registered at once. `drop` closes it as Salix does. */
  readonly relaySockets: FakeRelaySocket[] = [];
  readonly #stations = new Map<string, FakeStation>();
  readonly #now: () => number;

  /** `now`: the time credentials expire by (the test's clock). */
  constructor(now: () => number) {
    this.#now = now;
  }

  /** A station on the mesh, serving members of `workspace`. */
  station(id: string, workspace: string): FakeStation {
    const station = new FakeStation(id, workspace);
    this.#stations.set(id, station);
    serveMesh<Claims>({
      endpoint: this.mesh.endpoint(id, [MESH_ALPN]),
      now: this.#now,
      verify: async (credential, peer) => {
        const claims = JSON.parse(credential) as Claims;
        if (claims.ws !== station.takes)
          throw new MeshError("unauthorized", "credential is for another workspace");
        if (claims.device !== peer)
          throw new MeshError("unauthorized", "credential is for another device");
        if (claims.exp * 1000 <= this.#now())
          throw new MeshError("unauthorized", "credential expired");
        station.admitted.push(claims);
        return { principal: claims, expiresAtMs: claims.exp * 1000 };
      },
      handle: (request) => station.handle(request),
    });
    return station;
  }

  /** The ports a FakeHost gives the core. */
  readonly ports: StationMeshPorts = {
    open: ({ secretKey, relays }) =>
      Effect.acquireRelease(
        Effect.suspend(() => {
          const id = `device-${Buffer.from(secretKey.subarray(0, 4)).toString("hex")}`;
          this.bound.push({ id, relays: [...relays] });
          this.open = true;
          const links = meshStationLinks(
            this.mesh.endpoint(id),
            {},
            this.salix ? { carry: (url, ticket) => this.#carry(url, ticket) } : null
          );
          return Effect.succeed(links);
        }),
        (links) =>
          Effect.sync(() => {
            this.open = false;
            links.close();
          })
      ),
  };

  #carry(
    url: string,
    ticket: string
  ): Promise<{ closed: Promise<void>; close(): void }> {
    let drop!: () => void;
    const closed = new Promise<void>((done) => (drop = done));
    const socket: FakeRelaySocket = {
      url,
      ticket,
      open: true,
      drop: () => {
        socket.open = false;
        drop();
      },
    };
    this.relaySockets.push(socket);
    return Promise.resolve({ closed, close: () => socket.drop() });
  }

  /** Fails binding, as a platform without the native addon does. */
  unavailable(message = "no iroh here"): StationMeshPorts {
    return { open: () => Effect.fail(new HostError(message)) };
  }
}

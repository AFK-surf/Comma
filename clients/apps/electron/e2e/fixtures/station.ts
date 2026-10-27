import type { IncomingMessage, ServerResponse } from "node:http";
import { resolve } from "node:path";
import { MESH_ALPN, MeshError, serveMesh, type MeshReply } from "@comma/mesh";
import { bindNativeEndpoint, loadNativeMesh } from "@comma/mesh/station-native";
import { stationMeshAddonDistPath } from "../../scripts/native-paths";

/** The mesh addon the app's core loads: the one in the station the app carries (build-native.ts). */
const meshAddon = stationMeshAddonDistPath(resolve(__dirname, "../.."));

const answer = (status: number, value: unknown): MeshReply => ({
  body: new TextEncoder().encode(JSON.stringify(value)),
  headers: [["content-type", "application/json"]],
  status,
});

const json = (res: ServerResponse, value: unknown) =>
  res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(value));

async function bodyOf(req: IncomingMessage) {
  let text = "";
  for await (const chunk of req) text += String(chunk);
  return text === "" ? {} : (JSON.parse(text) as Record<string, unknown>);
}

/**
 * A station for the station-hosted Tasks E2E: an endpoint on the station's mesh addon, on loopback, serving
 * `comma/mesh/1` with the parts of the admin API the app uses (a Task whose agent asks with an options card, Tasks made
 * from the app, their status, the milestones their agents record, the event stream, the profiles a Task runs on), and
 * the control plane's routes for the
 * chat stub (`extraRoutes`): the workspace's stations, their member credential, and the Task index Comma lists. The
 * member credential the stub signs is JSON naming the workspace and the device; the station admits it only from that
 * device.
 */
export async function startE2eStation({
  name: stationName,
  workspace,
  group,
}: {
  name: string;
  /** The chat stub's workspace, and its Group (the Task index is listed by Group). */
  workspace: string;
  group: string;
}) {
  const endpoint = await bindNativeEndpoint(loadNativeMesh(meshAddon), {
    // A fixed key: the station is only on loopback, for this run.
    secretKey: new Uint8Array(32).fill(7),
    alpns: [MESH_ALPN],
    bindAddr: "127.0.0.1:0",
  });
  const addresses = [`127.0.0.1:${endpoint.sockets()[0]!.split(":").at(-1)}`];
  let access = "off";
  const admitted: string[] = [];
  const posted: { path: string; body: unknown }[] = [];
  /** What each Task made from the app was asked with (`POST /sessions`). */
  const made: Record<string, unknown>[] = [];
  /** Each Task's status, by thread, as people set it (`PUT /threads/:id/status`). */
  const statuses = new Map<number, string>([[7, "needs_review"]]);
  /** Each Task's labels, by thread, as people set them (`PUT /threads/:id/labels`). */
  const labels = new Map<number, string[]>([[7, ["lbl_ship"]]]);
  /** What the station was asked, by kind and in order: a test waits for the request itself, not for time to pass. */
  const heard = { made: 0, posted: 0, status: 0, labels: 0 };
  const hearing: { kind: keyof typeof heard; count: number; heard: () => void }[] = [];
  const hear = (kind: keyof typeof heard) => {
    heard[kind] += 1;
    for (const waiting of hearing.filter(
      (w) => w.kind === kind && heard[kind] >= w.count
    )) {
      hearing.splice(hearing.indexOf(waiting), 1);
      waiting.heard();
    }
  };
  // A fixed past moment: the station's chat happened before the app looked at it.
  const now = Date.UTC(2026, 9, 1, 9, 0);
  const asking = {
    seq: 2,
    message: {
      seq: 2,
      ts: "2",
      authorKind: "agent",
      author: "s_agent",
      authorName: "Opus 5.5",
      text: "Two ways to fix it. Which one?",
      createdAt: now - 60_000,
    },
    before: [
      {
        seq: 1,
        ts: "1",
        authorKind: "person",
        author: "stations-e2e@example.com",
        authorName: "Owner",
        text: "Fix the flaky checkout test.",
        createdAt: now - 120_000,
      },
    ],
    card: {
      type: "options",
      options: [{ label: "Not now" }, { label: "Add a ready hook", recommended: true }],
    },
  };
  let chat: Record<string, unknown> = {
    id: "s_agent",
    session: "s_agent",
    thread: 7,
    title: "Fix flaky checkout test",
    agents: [
      {
        key: "s_agent",
        runtime: "claude",
        process: "running",
        pending: 0,
        lastTurn: null,
      },
    ],
    last: { seq: 2, text: "Two ways to fix it. Which one?", createdAt: now - 60_000 },
    unread: false,
    lastActiveAt: now - 60_000,
    creator: { id: "usr_e2e", email: "stations-e2e@example.com", name: "E2E" },
    card: asking,
  };
  const entry = (
    n: number,
    authorKind: string,
    text: string,
    extra: Record<string, unknown> = {}
  ) => ({
    n,
    kind: "message",
    target: null,
    ts: String(n),
    authorKind,
    author: authorKind === "agent" ? "s_agent" : "stations-e2e@example.com",
    authorName: authorKind === "agent" ? "Opus 5.5" : "Owner",
    text,
    attachments: [],
    quotes: [],
    at: now - 120_000 + n * 1_000,
    ...extra,
  });
  /** The station's Tasks (its page chats), by thread. */
  const threads = new Map<
    number,
    { title: string; entries: Record<string, unknown>[] }
  >([
    [
      7,
      {
        title: "Fix flaky checkout test",
        entries: [
          entry(1, "person", "Fix the flaky checkout test."),
          entry(2, "agent", "Two ways to fix it. Which one?", { card: asking.card }),
        ],
      },
    ],
  ]);
  /** The files sent in its chats, by the name each has in its session's uploads (`GET /sessions/:key/files`). */
  const uploads = new Map<string, { type: string; bytes: Uint8Array }>();
  const listeners = new Set<(event: string) => void>();
  const say = (name: string, data: unknown) => {
    for (const listener of listeners)
      listener(`event: ${name}\ndata: ${JSON.stringify(data)}\n\n`);
  };
  const server = serveMesh<{ device: string }>({
    endpoint,
    handle: async (request) => {
      let text = "";
      for await (const chunk of request.body) text += new TextDecoder().decode(chunk);
      const route = `${request.method} ${request.path}`;
      if (route === "GET /events") {
        const queue: string[] = ["retry: 3000\n\n"];
        let wake: (() => void) | null = null;
        const listener = (event: string) => {
          queue.push(event);
          wake?.();
        };
        listeners.add(listener);
        request.signal.addEventListener("abort", () => wake?.());
        return {
          body: (async function* () {
            try {
              while (!request.signal.aborted) {
                const next = queue.shift();
                if (next !== undefined) yield new TextEncoder().encode(next);
                else await new Promise<void>((r) => (wake = r));
              }
            } finally {
              listeners.delete(listener);
            }
          })(),
          headers: [["content-type", "text/event-stream"]],
          status: 200,
        };
      }
      if (route === "GET /chats") return answer(200, [chat]);
      if (route === "GET /jobs") return answer(200, []);
      if (route === "GET /overview")
        return answer(200, {
          profiles: [
            {
              id: "work",
              name: "Work",
              runtime: "codex",
              runtimes: ["codex"],
              model: "gpt-5.5",
              models: ["gpt-5.5", "gpt-5.4"],
            },
          ],
        });
      if (route === "POST /sessions") {
        const body = JSON.parse(text) as Record<string, unknown>;
        made.push(body);
        hear("made");
        const id = 7 + made.length;
        threads.set(id, { title: "Run the checkout tests", entries: [] });
        statuses.set(id, "in_progress");
        return answer(200, { key: `s_codex_${id}`, thread: { id } });
      }
      const at = /^\/threads\/(\d+)(?:\/([a-z]+))?/.exec(request.path);
      const thread = at ? threads.get(Number(at[1])) : undefined;
      if (at && thread) {
        const id = Number(at[1]);
        const action = at[2];
        if (request.method === "GET" && action === undefined)
          return answer(200, {
            id,
            title: thread.title,
            last: thread.entries.length,
            read: thread.entries.length,
          });
        if (request.method === "GET" && action === "entries") {
          const after = new URLSearchParams(request.path.split("?")[1] ?? "").get(
            "after"
          );
          return answer(200, {
            last: thread.entries.length,
            entries: thread.entries.filter(
              (e) => after === null || (e.n as number) > Number(after)
            ),
          });
        }
        if (request.method === "PUT" && action === "read")
          return answer(200, { n: thread.entries.length, thread: id });
        if (request.method === "PUT" && action === "labels") {
          const asked = (JSON.parse(text) as { labels: string[] }).labels;
          labels.set(id, [...new Set(asked)].toSorted());
          hear("labels");
          return answer(200, { thread: id, labels: labels.get(id) });
        }
        if (request.method === "PUT" && action === "status") {
          const status = (JSON.parse(text) as { status: string }).status;
          statuses.set(id, status === "in_progress" ? "needs_review" : status);
          hear("status");
          return answer(200, { thread: id, status: statuses.get(id) });
        }
        if (request.method === "POST" && action === "messages") {
          const body = JSON.parse(text) as { quotes?: { ts?: string }[]; text: string };
          posted.push({ body, path: request.path });
          hear("posted");
          const said = entry(thread.entries.length + 1, "person", body.text, {
            quotes: body.quotes ?? [],
          });
          thread.entries.push(said);
          // A message that quotes the card answers it: the agent goes on, and the card no longer waits.
          if (id === 7 && body.quotes?.some((q) => q.ts === "2")) {
            const { card: _answered, ...rest } = chat;
            chat = rest;
          }
          // The station tells every open event stream; whether that reaches the app before this answer is the
          // network's, as with a real station.
          say("thread", { id, entries: [said] });
          if (id === 7) say("chat", chat);
          return answer(200, { n: said.n });
        }
      }
      const sessionFile = /^\/sessions\/[^/?]+\/files\?/.exec(request.path);
      if (request.method === "GET" && sessionFile) {
        const name = new URLSearchParams(request.path.split("?")[1]).get("name") ?? "";
        const file = uploads.get(name);
        return file
          ? { body: file.bytes, headers: [["content-type", file.type]], status: 200 }
          : answer(404, { error: "No such file" });
      }
      if (request.path === "/tools/access" && request.method === "GET")
        return answer(200, { access });
      if (request.path === "/tools/access" && request.method === "PUT") {
        access = (JSON.parse(text) as { access: string }).access;
        return answer(200, { access });
      }
      return answer(404, { error: `no route ${request.method} ${request.path}` });
    },
    verify: async (credential, peer) => {
      const claims = JSON.parse(credential) as { device: string; ws: string };
      if (claims.ws !== workspace || claims.device !== peer)
        throw new MeshError("unauthorized", "not a member's credential");
      admitted.push(peer);
      return { principal: { device: peer } };
    },
  });
  const base = `/v1/comma/workspaces/${workspace}`;
  // Enrollments and credentials the app accepts whenever the run happens (2100-01-01, in seconds).
  const farFuture = 4_102_444_800;
  const stationRow = {
    enrolled_at: 1_700_000_000,
    enrolled_by: "e2e",
    id: endpoint.id,
    name: stationName,
    online: true,
    version: "1.0.0",
  };
  return {
    id: endpoint.id,
    admitted,
    posted,
    made,
    status: (thread: number) => statuses.get(thread),
    /**
     * The Task's agent records milestones alone (chat_post `milestones`): a `milestone` entry, written and said on the
     * event stream as the station does.
     */
    record: (id: number, titles: string[]) => {
      const thread = threads.get(id)!;
      const recorded = entry(thread.entries.length + 1, "agent", "", {
        kind: "milestone",
        milestones: titles,
        text: null,
      });
      thread.entries.push(recorded);
      say("thread", { id, entries: [recorded] });
    },
    /** The Task's agent posts `text` with a picture (chat_post `files`), kept in its session's uploads. */
    post: (id: number, text: string, picture: { name: string; bytes: Uint8Array }) => {
      const thread = threads.get(id)!;
      const kept = `2026-10-01-${picture.name}`;
      uploads.set(kept, { type: "image/png", bytes: picture.bytes });
      const said = entry(thread.entries.length + 1, "agent", text, {
        attachments: [
          {
            name: picture.name,
            path: `/work/s_agent/uploads/${kept}`,
            size: picture.bytes.length,
          },
        ],
      });
      thread.entries.push(said);
      say("thread", { id, entries: [said] });
    },
    labels: (thread: number) => labels.get(thread) ?? [],
    /** Resolves once the station has been asked `count` requests of `kind` (a Task made, a message, a status). */
    heard: (kind: keyof typeof heard, count: number) =>
      new Promise<void>((done) =>
        heard[kind] >= count ? done() : hearing.push({ kind, count, heard: done })
      ),
    access: () => access,
    /** For `COMMA_ELECTRON_E2E_STATION_PEERS`: where the app's core finds it. */
    peers: JSON.stringify({ [endpoint.id]: addresses }),
    /** The control plane's stations routes, for the chat stub. */
    routes: async (req: IncomingMessage, url: URL, res: ServerResponse) => {
      const route = `${req.method} ${url.pathname}`;
      if (route === "GET /v1/comma/stations/me") {
        json(res, {
          relay_urls: [],
          user: { email: "stations-e2e@example.com", id: "usr_e2e", name: "E2E" },
          workspaces: [{ id: workspace, name: "Smoke Workspace", role: "owner" }],
        });
        return true;
      }
      // The workspace's computers: the one this station runs on.
      if (route === `GET /v1/comma/workspaces/${workspace}/devices`) {
        json(res, {
          devices: [
            {
              device_id: "dev_studio",
              name: stationName,
              status: "connected",
              allows_operations: false,
              access: "read",
              station_id: endpoint.id,
              tasks_readiness: "ready",
              os: "darwin",
            },
          ],
          next_cursor: null,
        });
        return true;
      }
      if (route === `GET /v1/comma/groups/${group}/station-tasks`) {
        json(res, {
          tasks: [...threads].map(([id, thread]) => ({
            station_id: endpoint.id,
            device_id: null,
            thread: String(id),
            task: `EMBER/${id}.0`,
            title: thread.title,
            status: statuses.get(id) ?? "in_progress",
            created_by: "stations-e2e@example.com",
            created_at: now - 300_000 + id,
            last_activity_at: now - 60_000 + id,
            runtime: id === 7 ? "claude" : "codex",
            model:
              id === 7 ? "claude-opus-5-5" : String(made[id - 8]?.model ?? "gpt-5.5"),
            labels: labels.get(id) ?? [],
            rev: 1,
          })),
        });
        return true;
      }
      if (route === `GET ${base}/stations`) {
        json(res, { stations: [stationRow] });
        return true;
      }
      if (route === `GET ${base}/stations/events`) {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(": connected\n\n");
        return true;
      }
      if (route === `POST ${base}/stations/enrollments`) {
        json(res, {
          command: "curl -fsSL http://127.0.0.1/stations/install.sh | sh -s -- enr_e2e",
          expires_at: farFuture,
          token: "enr_e2e",
        });
        return true;
      }
      if (route === `POST ${base}/station-credential`) {
        const { device } = await bodyOf(req);
        const exp = farFuture;
        json(res, {
          credential: JSON.stringify({ device, exp, role: "owner", ws: workspace }),
          expires_at: exp,
          issued_at: exp - 3_600,
          relay_urls: [],
        });
        return true;
      }
      return false;
    },
    close: async () => {
      server.close();
      await endpoint.close();
    },
  };
}

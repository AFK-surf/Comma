// A stand-in for Slack on a local port: its Web API (each call recorded and answered by the test) and Socket Mode
// (apps.connections.open gives a socket on the same port; the test sends envelopes down it and sees what the station
// acknowledges). Nothing reaches the real Slack.
import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type WebSocket } from "ws";

type Json = any;

/// A call Slack's stand-in saw: its method (the path), its bearer token, its fields (form or multipart text), its body.
export type Seen = { method: string; auth: string; params: Record<string, string>; body: string; contentType: string };

export type Answer = (seen: Seen) => Json | Promise<Json>;

export class FakeSlack {
  readonly server: Server;
  readonly wss: WebSocketServer;
  base = "";
  seen: Seen[] = [];
  /// Answers by method; a method without one answers `{ ok: true }` (and a ts for chat.postMessage).
  answers = new Map<string, Answer>();
  /// The sockets opened, newest last.
  sockets: WebSocket[] = [];
  /// What came up each socket (acks), parsed.
  acks: Json[] = [];
  /// Whether a socket answers pings (false: like a connection cut off on the way).
  answersPings = true;
  /// The pings that came, answered or not.
  pings = 0;
  private waiters: (() => void)[] = [];
  private ts = 1;

  constructor() {
    this.server = createServer((req, res) => {
      void this.take(req).then(
        (reply) => {
          const text = JSON.stringify(reply.body);
          res.writeHead(reply.status, { "content-type": "application/json", ...reply.headers }).end(text);
        },
        (error) => res.writeHead(500).end(String(error)),
      );
    });
    this.wss = new WebSocketServer({ noServer: true, autoPong: false });
    this.server.on("upgrade", (req, socket, head) => {
      this.wss.handleUpgrade(req, socket, head, (ws) => {
        this.sockets.push(ws);
        ws.on("ping", (data) => {
          this.pings++;
          if (this.answersPings) ws.pong(data);
          this.tell();
        });
        ws.on("message", (data) => {
          try {
            this.acks.push(JSON.parse(String(data)));
          } catch {}
          this.tell();
        });
        this.tell();
      });
    });
  }

  static async start(): Promise<FakeSlack> {
    const fake = new FakeSlack();
    await new Promise<void>((resolve) => fake.server.listen(0, "127.0.0.1", resolve));
    fake.base = `http://127.0.0.1:${(fake.server.address() as AddressInfo).port}/api`;
    return fake;
  }

  /// Socket Mode's address on this stand-in.
  socketUrl(): string {
    return this.base.replace(/^http/, "ws").replace(/\/api$/, "/socket");
  }

  /// The calls of a method, in order.
  calls(method: string): Seen[] {
    return this.seen.filter((s) => s.method === method);
  }

  answer(method: string, answer: Answer | Record<string, unknown>) {
    this.answers.set(method, typeof answer === "function" ? (answer as Answer) : () => answer);
  }

  /// Sends an Events API envelope down the newest socket.
  send(envelope: Json) {
    const ws = this.sockets.at(-1);
    if (!ws) throw new Error("no socket open");
    ws.send(JSON.stringify(envelope));
  }

  /// An `events_api` envelope carrying `event`.
  event(id: string, event: Json) {
    this.send({ type: "events_api", envelope_id: id, payload: { event } });
  }

  /// Resolves once `f` holds (looked at whenever the stand-in heard something, and every 20 ms). No deadline: what is
  /// waited for comes, however slow the machine, or the test hangs.
  async until(_what: string, f: () => boolean) {
    while (!f()) {
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve);
        setTimeout(resolve, 20);
      });
    }
  }

  private tell() {
    for (const w of this.waiters.splice(0)) w();
  }

  async close() {
    for (const ws of this.sockets) ws.terminate();
    this.wss.close();
    this.server.closeAllConnections();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }

  private async take(req: IncomingMessage): Promise<{ status: number; headers: Record<string, string>; body: Json }> {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    const raw = Buffer.concat(chunks);
    const contentType = String(req.headers["content-type"] ?? "");
    const params: Record<string, string> = {};
    if (contentType.startsWith("application/x-www-form-urlencoded")) {
      for (const [k, v] of new URLSearchParams(raw.toString("utf8"))) params[k] = v;
    } else if (contentType.startsWith("multipart/form-data")) {
      const form = await new Response(raw, { headers: { "content-type": contentType } }).formData();
      for (const [k, v] of form) if (typeof v === "string") params[k] = v;
    }
    const path = (req.url ?? "/").split("?")[0]!;
    const method = path.replace(/^\/api\//, "").replace(/^\//, "");
    const seen: Seen = { method, auth: String(req.headers.authorization ?? "").replace(/^Bearer /, ""), params, body: raw.toString("latin1"), contentType };
    this.seen.push(seen);
    this.tell();
    const answer = this.answers.get(method);
    if (answer) {
      const body = await answer(seen);
      if (body && typeof body === "object" && "__status" in body) return { status: body.__status, headers: body.__headers ?? {}, body: body.__body ?? {} };
      return { status: 200, headers: {}, body };
    }
    if (method === "apps.connections.open") return { status: 200, headers: {}, body: { ok: true, url: this.socketUrl() } };
    if (method === "chat.postMessage") return { status: 200, headers: {}, body: { ok: true, ts: `${8_000_000 + this.ts++}.000100` } };
    return { status: 200, headers: {}, body: { ok: true } };
  }
}

/// What a fake Slack says a bot is (auth.test and users.info), for a team.
export function bot(fake: FakeSlack, o: { user?: string; team?: string; teamId?: string; name?: string; botId?: string; image?: string } = {}) {
  const user = o.user ?? "UBOT";
  fake.answer("auth.test", { ok: true, user_id: user, user: "ember_bot", team: o.team ?? "Acme", team_id: o.teamId ?? "T1", url: "https://acme.slack.com/", bot_id: o.botId ?? "BBOT" });
  fake.answer("users.info", (s: Seen) =>
    s.params.user === user
      ? { ok: true, user: { id: user, real_name: "ember", profile: { display_name: o.name ?? "ember", image_72: o.image ?? "https://avatars.slack-edge.com/ember_72.png" } } }
      : { ok: true, user: { id: s.params.user, name: "ada", real_name: "Ada L", profile: { display_name: "Ada", email: "Ada@Example.test" } } },
  );
}

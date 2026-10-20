// the Rust station's preview.rs's tests ported (same names, same checks): a web service on this machine reached through the
// preview proxy, and a service's WebSocket bridged to a client's stream in frames.
import assert from "node:assert/strict";
import { type Server, type Socket, createServer } from "node:net";
import type { AddressInfo } from "node:net";
import type { Readable } from "node:stream";
import { test } from "node:test";
import { WebSocketServer } from "ws";
import {
  type ByteSink, type ByteSource, FRAME_BINARY, FRAME_CLOSE, FRAME_TEXT, FrameReader, type PreviewAnswer, SocketRefused, frame,
  openSocket, previewTarget, proxyPreview, pumpSocket,
} from "../src/jobs/preview.ts";

/// A one-request-at-a-time HTTP service: echoes what it was asked in x-seen, forbids framing, redirects /old.
async function service(): Promise<{ port: number; server: Server; sockets: Set<Socket> }> {
  const sockets = new Set<Socket>();
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    let got = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      got = Buffer.concat([got, chunk]);
      const end = got.indexOf("\r\n\r\n");
      if (end < 0) return;
      const head = got.subarray(0, end).toString();
      const header = (name: string) =>
        head.split("\r\n").map((l) => l.split(/:(.*)/s)).find(([k]) => k.toLowerCase() === name)?.[1]?.trim();
      const length = Number(header("content-length") ?? 0);
      if (got.length < end + 4 + length) return;
      const body = got.subarray(end + 4).toString();
      const target = head.split("\r\n")[0].split(" ").slice(0, 2).join(" ");
      let answer: string;
      if (target.endsWith(" /old")) {
        answer = `HTTP/1.1 302 Found\r\nlocation: http://localhost:${port}/new?x=1\r\ncontent-length: 0\r\nconnection: close\r\n\r\n`;
      } else {
        const seen = `${target} ${header("host") ?? ""} ${header("traceparent") ?? "-"} ${body}`;
        const text = "hello from the service";
        answer = `HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nx-frame-options: DENY\r\ncontent-security-policy: frame-ancestors 'none'\r\nx-seen: ${seen}\r\ncontent-length: ${text.length}\r\nconnection: close\r\n\r\n${text}`;
      }
      socket.end(answer);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  return { port, server, sockets };
}

async function stop(s: { server: Server; sockets: Set<Socket> }) {
  for (const socket of s.sockets) socket.destroy();
  await new Promise((resolve) => s.server.close(resolve));
}

async function text(body: Readable): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of body) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString();
}

const header = (answer: PreviewAnswer, name: string) => answer.headers.find(([k]) => k === name)?.[1];

test("a web service on the machine is reached as it answers, framing allowed", async () => {
  const s = await service();
  const port = s.port;
  const asked: [string, string][] = [
    ["traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"],
    ["x-stillfail-mesh", "secret"],
    ["x-ember-mesh", "secret"],
    ["content-type", "text/plain"],
  ];
  const [targetPort, path] = previewTarget(`/preview/${port}/a/b?q=1`)!;
  const got = await proxyPreview("POST", asked, Buffer.from("x=1"), targetPort, path, "zh");
  assert.equal(got.status, 200);
  assert.equal(header(got, "x-seen"), `POST /a/b?q=1 localhost:${port} - x=1`, "the path and query as asked, the service's own host, none of the admin call's headers");
  assert.deepEqual([header(got, "x-frame-options"), header(got, "content-security-policy")], [undefined, undefined]);
  assert.equal(await text(got.body), "hello from the service");
  const moved = await proxyPreview("GET", [], null, port, "/old", "zh");
  assert.deepEqual([moved.status, header(moved, "location")], [302, "/new?x=1"], "a redirect to the service stays on it");
  await text(moved.body);
  await stop(s);
  const gone = await proxyPreview("GET", [], null, port, "/", "zh");
  assert.equal(gone.status, 502);
  assert.ok((await text(gone.body)).includes(`localhost:${port} 没有回应`));
  assert.equal(previewTarget("/preview/99999/"), null, "not a port");
  assert.deepEqual(previewTarget("/preview/8080"), [8080, "/"]);
  assert.equal((await proxyPreview("GE T", [], null, port, "/", "en")).status, 400);
});

/// A WebSocket service: checks the origin it was opened from and the sub-protocol asked for, then echoes each message
/// back with what it saw first, and closes with 4001 when told "bye".
async function socketService(): Promise<{ port: number; close: () => Promise<void> }> {
  const server = new WebSocketServer({ host: "127.0.0.1", port: 0, handleProtocols: (protocols) => [...protocols][0] ?? false });
  await new Promise<void>((resolve) => server.on("listening", resolve));
  server.on("connection", (ws, request) => {
    const h = (n: string) => (request.headers[n] as string | undefined) ?? "-";
    const seen = `${request.url} ${h("origin")} ${h("sec-websocket-protocol")} ${h("x-stillfail-mesh")} ${h("x-ember-mesh")}`;
    ws.on("message", (data, isBinary) => {
      if (isBinary) return ws.send(data, { binary: true });
      const t = data.toString();
      if (t === "bye") return ws.close(4001, "done");
      ws.send(`${seen} | ${t}`);
    });
  });
  return {
    port: (server.address() as AddressInfo).port,
    close: () => {
      for (const c of server.clients) c.terminate();
      return new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

/// One direction of an in-memory stream: what is written is read, in order, then null once finished.
class Pipe implements ByteSource, ByteSink {
  private queue: (Buffer | null)[] = [];
  private waiting: ((b: Buffer | null) => void) | null = null;
  private push(b: Buffer | null) {
    const w = this.waiting;
    if (w) {
      this.waiting = null;
      w(b);
    } else this.queue.push(b);
  }
  async write(bytes: Buffer) {
    this.push(bytes);
  }
  async finish() {
    this.push(null);
  }
  read(): Promise<Buffer | null> {
    if (this.queue.length > 0) {
      const b = this.queue.shift()!;
      if (b === null) this.queue.unshift(null);
      return Promise.resolve(b);
    }
    return new Promise((resolve) => (this.waiting = resolve));
  }
}

/// A client's stream to a pump: frames written to `up`, read from `down`.
function client() {
  const up = new Pipe();
  const down = new Pipe();
  return { up, down, reading: new FrameReader(down) };
}

test("a service's websocket passes messages both ways, framed, until it closes", async () => {
  const s = await socketService();
  const port = s.port;
  const asked: [string, string][] = [["sec-websocket-protocol", "vite-hmr"], ["x-stillfail-mesh", "secret"], ["x-ember-mesh", "secret"]];
  const socket = await openSocket(asked, port, "/hmr?token=1", "zh");
  assert.equal(socket.protocol, "vite-hmr");
  const c = client();
  const pump = pumpSocket(socket, new FrameReader(c.up), c.down);
  await c.up.write(frame(FRAME_TEXT, Buffer.from("hi")));
  await c.up.write(frame(FRAME_BINARY, Buffer.from([0, 1, 2])));
  const got = (await c.reading.next())!;
  assert.deepEqual([got[0], got[1].toString()], [FRAME_TEXT, `/hmr?token=1 http://localhost:${port} vite-hmr - - | hi`], "the path, the service's own origin, the sub-protocol; none of still.fail's headers (either name)");
  assert.deepEqual(await c.reading.next(), [FRAME_BINARY, Buffer.from([0, 1, 2])]);
  await c.up.write(frame(FRAME_TEXT, Buffer.from("bye")));
  const [kind, payload] = (await c.reading.next())!;
  assert.deepEqual([kind, payload.readUInt16BE(0), payload.subarray(2).toString()], [FRAME_CLOSE, 4001, "done"], "the service's close, with its code and reason");
  assert.equal(await c.reading.next(), null, "then the stream ends");
  await pump;
  await s.close();
});

test("a close from the client is answered by the service's own", async () => {
  const s = await socketService();
  const socket = await openSocket([], s.port, "/", "zh");
  const c = client();
  const pump = pumpSocket(socket, new FrameReader(c.up), c.down);
  await c.up.write(frame(FRAME_CLOSE, Buffer.concat([Buffer.from([0x0f, 0xa2]), Buffer.from("leaving")])));
  const [kind, payload] = (await c.reading.next())!;
  assert.deepEqual([kind, payload.readUInt16BE(0)], [FRAME_CLOSE, 4002], "the service's close comes back");
  await pump;
  await s.close();
});

test("a client gone closes the service's socket, and a refusal says why", async () => {
  const s = await socketService();
  const socket = await openSocket([], s.port, "/", "zh");
  const c = client();
  const pump = pumpSocket(socket, new FrameReader(c.up), c.down);
  await c.up.finish();
  await pump;
  await s.close();
  // A port with plain HTTP on it (no socket there) and one with nothing at all.
  const http = await service();
  const refused = await openSocket([], http.port, "/", "zh").then(() => null, (e: SocketRefused) => e);
  assert.ok(refused instanceof SocketRefused && refused.status >= 400, String(refused));
  await stop(http);
  const none = await openSocket([], http.port, "/", "zh").then(() => null, (e: SocketRefused) => e);
  assert.ok(none instanceof SocketRefused);
  assert.equal(none.status, 502);
  assert.ok(none.message.includes(`localhost:${http.port} 没有回应`), none.message);
});

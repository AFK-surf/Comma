import { describe, expect, it } from "vitest";
import {
  MESH_ALPN,
  MeshClient,
  MeshError,
  serveMesh,
  serveMeshConnection,
  type Admission,
  type MeshReply,
  type PeerAddr,
  type ServedRequest,
} from "../src/index.ts";
import { MemoryMesh } from "../src/memory.ts";
import { FrameReader, encodeFrame } from "../src/wire.ts";

const text = (s: string) => new TextEncoder().encode(s);
async function readAll(body: AsyncIterable<Uint8Array>): Promise<string> {
  let out = "";
  const decoder = new TextDecoder();
  for await (const chunk of body) out += decoder.decode(chunk, { stream: true });
  return out + decoder.decode();
}

/** A body whose pieces the test hands over one at a time. */
function pieces() {
  const queue: (Uint8Array | null)[] = [];
  let wake: (() => void) | null = null;
  return {
    push(piece: Uint8Array | null) {
      queue.push(piece);
      wake?.();
      wake = null;
    },
    async *body() {
      for (;;) {
        while (queue.length === 0) await new Promise<void>((r) => (wake = r));
        const next = queue.shift()!;
        if (next === null) return;
        yield next;
      }
    },
  };
}

type Principal = { user: string };

function setup(
  handle: (request: ServedRequest<Principal>) => Promise<MeshReply>,
  verify?: (credential: string, peer: string) => Promise<Admission<Principal>>
) {
  const mesh = new MemoryMesh();
  const station = mesh.endpoint("station", [MESH_ALPN]);
  const app = mesh.endpoint("app");
  const verified: { credential: string; peer: string }[] = [];
  const errors: unknown[] = [];
  const server = serveMesh<Principal>({
    endpoint: station,
    verify:
      verify ??
      (async (credential, peer) => {
        verified.push({ credential, peer });
        return { principal: { user: credential.replace("cred-", "") } };
      }),
    handle,
    onError: (error) => errors.push(error),
  });
  let issued = 0;
  const client = new MeshClient({
    endpoint: app,
    credential: async () => `cred-u${++issued}`,
  });
  const peer: PeerAddr = { id: "station" };
  return { mesh, server, client, peer, verified, errors, issued: () => issued };
}

describe("the mesh", () => {
  it("carries a request and its answer, both bodies streamed, with the principal the credential names", async () => {
    const seen: {
      principal: Principal;
      path: string;
      headers: [string, string][];
      body: string;
    }[] = [];
    const answer = pieces();
    const t = setup(async (request) => {
      seen.push({
        principal: request.principal,
        path: request.path,
        headers: request.headers,
        body: await readAll(request.body),
      });
      return {
        status: 201,
        headers: [["content-type", "text/plain"]],
        body: answer.body(),
      };
    });
    const sent = pieces();
    const pending = t.client.request(t.peer, {
      method: "POST",
      path: "/files?x=1",
      headers: [["x-a", "1"]],
      body: sent.body(),
    });
    sent.push(text("hel"));
    sent.push(text("lo"));
    sent.push(null);
    const response = await pending;
    expect(response.status).toBe(201);
    expect(response.headers).toEqual([["content-type", "text/plain"]]);
    answer.push(text("wor"));
    answer.push(text("ld"));
    answer.push(null);
    expect(await readAll(response.body)).toBe("world");
    expect(seen).toEqual([
      {
        principal: { user: "u1" },
        path: "/files?x=1",
        headers: [["x-a", "1"]],
        body: "hello",
      },
    ]);
    expect(t.verified).toEqual([{ credential: "cred-u1", peer: "app" }]);
  });

  it("refuses a credential the server refuses, with its words, and no request reaches the handler", async () => {
    let handled = 0;
    const t = setup(
      async () => {
        handled += 1;
        return { status: 200 };
      },
      async () => {
        throw new MeshError("not_a_member", "This station is not in your workspace.");
      }
    );
    await expect(
      t.client.request(t.peer, { method: "GET", path: "/" })
    ).rejects.toMatchObject({
      code: "not_a_member",
      message: "This station is not in your workspace.",
    });
    expect(handled).toBe(0);
  });

  it("serves a connection the caller accepted itself, beside the caller's own protocols", async () => {
    const mesh = new MemoryMesh();
    const station = mesh.endpoint("station", [MESH_ALPN, "other/1"]);
    // The station's own accept loop: it hands the mesh's connections on and keeps the rest.
    void (async () => {
      for (;;) {
        const connection = await station.accept();
        if (connection === null) return;
        void serveMeshConnection<Principal>(connection, {
          verify: async (credential) => ({ principal: { user: credential } }),
          handle: async (request) => ({
            status: 200,
            body: text(`${request.principal.user} ${request.path}`),
          }),
        });
      }
    })();
    const client = new MeshClient({
      endpoint: mesh.endpoint("app"),
      credential: async () => "u1",
    });
    const answer = await client.request(
      { id: "station" },
      { method: "GET", path: "/x" }
    );
    expect(await readAll(answer.body)).toBe("u1 /x");
  });

  it("keeps one connection per peer, and opens another with a fresh credential after the network went", async () => {
    const t = setup(async (request) => ({ status: 200, body: text(request.path) }));
    const answers = await Promise.all(
      ["/a", "/b", "/c"].map((path) =>
        t.client.request(t.peer, { method: "GET", path })
      )
    );
    expect(await Promise.all(answers.map((a) => readAll(a.body)))).toEqual([
      "/a",
      "/b",
      "/c",
    ]);
    expect(t.mesh.dialed).toBe(1);
    expect(t.issued()).toBe(1);

    t.mesh.cut();
    const again = await t.client.request(t.peer, { method: "GET", path: "/d" });
    expect(await readAll(again.body)).toBe("/d");
    expect(t.issued()).toBe(2);
    expect(t.verified.map((v) => v.credential)).toEqual(["cred-u1", "cred-u2"]);
  });

  it("connects without a request, shares that connection with requests, and says when it went", async () => {
    const t = setup(async (request) => ({ status: 200, body: text(request.path) }));
    const link = await t.client.connect(t.peer);
    expect(t.verified).toHaveLength(1);
    const answer = await t.client.request(t.peer, { method: "GET", path: "/a" });
    expect(await readAll(answer.body)).toBe("/a");
    expect(t.mesh.dialed).toBe(1);

    t.mesh.cut();
    await link.closed;
    await t.client.connect(t.peer);
    expect(t.mesh.dialed).toBe(1);
    expect(t.verified).toHaveLength(2);
  });

  it("renews an expired credential once and sends the request again; a streamed body is not sent twice", async () => {
    let now = 1_000;
    const handled: string[] = [];
    const mesh = new MemoryMesh();
    const station = mesh.endpoint("station", [MESH_ALPN]);
    serveMesh<Principal>({
      endpoint: station,
      // Each credential holds 100 ms.
      verify: async (credential) => ({
        principal: { user: credential },
        expiresAtMs: now + 100,
      }),
      handle: async (request) => {
        handled.push(`${request.principal.user} ${request.path}`);
        return { status: 200 };
      },
      now: () => now,
    });
    let issued = 0;
    const client = new MeshClient({
      endpoint: mesh.endpoint("app"),
      credential: async () => `c${++issued}`,
    });
    const peer = { id: "station" };
    await client.request(peer, { method: "GET", path: "/one" });
    now += 500;
    const second = await client.request(peer, {
      method: "POST",
      path: "/two",
      body: text("again"),
    });
    expect(second.status).toBe(200);
    expect(handled).toEqual(["c1 /one", "c2 /two"]);
    expect(mesh.dialed).toBe(1);

    now += 500;
    const streamed = pieces();
    streamed.push(text("once"));
    streamed.push(null);
    await expect(
      client.request(peer, { method: "POST", path: "/three", body: streamed.body() })
    ).rejects.toMatchObject({ code: "credential_expired" });
    expect(handled).toEqual(["c1 /one", "c2 /two"]);
  });

  it("gives a request up on both sides when the client aborts it", async () => {
    let aborted!: () => void;
    const handlerSawAbort = new Promise<void>((r) => (aborted = r));
    const answer = pieces();
    const t = setup(async (request) => {
      request.signal.addEventListener("abort", () => aborted(), { once: true });
      return { status: 200, body: answer.body() };
    });
    const controller = new AbortController();
    const response = await t.client.request(
      t.peer,
      { method: "GET", path: "/stream" },
      controller.signal
    );
    answer.push(text("first"));
    const iterator = response.body[Symbol.asyncIterator]();
    expect(new TextDecoder().decode((await iterator.next()).value)).toBe("first");
    controller.abort();
    await expect(iterator.next()).rejects.toMatchObject({ code: "cancelled" });
    answer.push(text("more"));
    await handlerSawAbort;
  });

  it("says a handler's failure as `internal` only, and the connection serves on", async () => {
    let fail = true;
    const t = setup(async () => {
      if (fail) throw new Error("disk on fire at /secret/path");
      return { status: 204 };
    });
    await expect(
      t.client.request(t.peer, { method: "GET", path: "/" })
    ).rejects.toMatchObject({
      code: "internal",
      message: "The request failed.",
    });
    expect(t.errors).toHaveLength(1);
    fail = false;
    expect((await t.client.request(t.peer, { method: "GET", path: "/" })).status).toBe(
      204
    );
    expect(t.mesh.dialed).toBe(1);
  });

  it("drops a request stream whose frame is over the limit or not one", async () => {
    const t = setup(async () => ({ status: 200 }));
    // Admitted through the client first, then a raw stream on a connection of the test's own.
    const mesh = t.mesh;
    const raw = await mesh.endpoint("raw").connect({ id: "station" }, MESH_ALPN);
    const control = await raw.openBi();
    await control.send.write(
      encodeFrame({ type: "hello", version: 1, credential: "cred-raw" })
    );
    const controlReader = new FrameReader((max) => control.recv.read(max));
    expect(await controlReader.frame()).toEqual({ type: "welcome" });

    const huge = await raw.openBi();
    const length = new Uint8Array(4);
    new DataView(length.buffer).setUint32(0, 1 << 30);
    await huge.send.write(length);
    await expect(huge.recv.read(1024)).rejects.toThrow();

    const junk = await raw.openBi();
    const bytes = text("not json");
    const head = new Uint8Array(4 + bytes.length);
    new DataView(head.buffer).setUint32(0, bytes.length);
    head.set(bytes, 4);
    await junk.send.write(head);
    await expect(junk.recv.read(1024)).rejects.toThrow();
  });
});

describe("frames", () => {
  it("read the same however the bytes are split", async () => {
    const frames = [
      { type: "a", n: 1 },
      { type: "b", s: "é".repeat(100) },
    ];
    const all = new Uint8Array([
      ...encodeFrame(frames[0]!),
      ...encodeFrame(frames[1]!),
      ...text("body"),
    ]);
    for (const size of [1, 3, 7, all.length]) {
      let at = 0;
      const reader = new FrameReader(async () => {
        if (at >= all.length) return null;
        const chunk = all.subarray(at, at + size);
        at += size;
        return chunk;
      });
      expect(await reader.frame()).toEqual(frames[0]);
      expect(await reader.frame()).toEqual(frames[1]);
      expect(await readAll(reader.body())).toBe("body");
    }
  });

  it("refuse to write a frame over the limit", () => {
    expect(() => encodeFrame({ type: "x", pad: "x".repeat(70_000) })).toThrow(
      MeshError
    );
  });
});

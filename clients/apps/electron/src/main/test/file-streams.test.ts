import { describe, expect, it, vi } from "vitest";
import { FileStreamRegistry, saveApiFile } from "../modules/core/file-streams";
import type { CommaApiCredentialAuthority } from "../protocol";
import type { MainProductCredentialLease } from "../modules/session";

vi.mock("electron-log/main", () => ({ default: { warn: vi.fn() } }));
vi.mock("electron", () => ({
  net: { fetch: vi.fn() },
  session: { fromPartition: () => ({ fetch: vi.fn() }) },
  protocol: { handle: vi.fn(), registerSchemesAsPrivileged: vi.fn() },
}));

const sessionLease = {
  audience: "https://api.comma.test",
  authorityInstanceId: "authority-1",
  generation: 3,
  sessionId: "session-1",
};
const path = "/v1/comma/groups/g/conversations/c/messages/m/attachments/2";

function authority(): CommaApiCredentialAuthority {
  const lease: MainProductCredentialLease = Object.freeze({
    ...sessionLease,
    signal: new AbortController().signal,
    token: "main_secret",
  });
  return {
    acquireProductCredential: (expected) =>
      expected.expectedSessionId === lease.sessionId &&
      expected.generation === lease.generation
        ? lease
        : null,
    admissionFailure: () => ({
      code: "session_product_lease_unavailable",
      recovery: { authorityInstanceId: "authority-1", generation: 3, revision: 1 },
    }),
    isCurrentProductCredential: (candidate) => candidate === lease,
  };
}

/** The API answering one range of a 12-byte file, as the attachment endpoint does. */
function api() {
  const requests: { url: string; headers: Headers }[] = [];
  const fetch = vi.fn(async (url: string, init: RequestInit) => {
    requests.push({ url, headers: new Headers(init.headers) });
    return new Response(new Uint8Array([4, 5, 6, 7]), {
      status: 206,
      headers: {
        "accept-ranges": "bytes",
        "content-range": "bytes 4-7/12",
        "content-type": "application/octet-stream",
        "content-disposition": "attachment; filename*=UTF-8''clip.mp4",
      },
    });
  });
  return { fetch, requests };
}

describe("Comma API files a window plays in ranges", () => {
  it("reads the range a media element asks for, under the session the core opened it for", async () => {
    const streams = new FileStreamRegistry();
    const url = streams.open({ path, type: "video/mp4", lease: sessionLease });
    const upstream = api();

    const answer = await streams.serve(
      new Request(url, { headers: { range: "bytes=4-7" } }),
      authority(),
      upstream.fetch
    );

    expect(url).toMatch(/^comma-file:\/\/stream\/[0-9a-f-]{36}$/);
    expect(upstream.requests).toHaveLength(1);
    expect(upstream.requests[0]!.url).toBe(`https://api.comma.test${path}`);
    expect(upstream.requests[0]!.headers.get("authorization")).toBe(
      "Bearer main_secret"
    );
    expect(upstream.requests[0]!.headers.get("range")).toBe("bytes=4-7");
    expect(answer.status).toBe(206);
    expect(Object.fromEntries(answer.headers)).toEqual({
      "accept-ranges": "bytes",
      "access-control-allow-origin": "*",
      "cache-control": "no-store",
      "content-length": "4",
      "content-security-policy": "sandbox",
      "content-range": "bytes 4-7/12",
      "content-type": "video/mp4",
      "x-content-type-options": "nosniff",
    });
    expect(new Uint8Array(await answer.arrayBuffer())).toEqual(
      new Uint8Array([4, 5, 6, 7])
    );
  });

  it("reads a signed URL in the range asked for, with no credential, as its own authority", async () => {
    const streams = new FileStreamRegistry();
    const signed = "https://blobs.example.test/b/clip?X-Amz-Signature=s";
    const url = streams.open({ url: signed, type: "video/mp4" });
    const reads: { url: string; init: RequestInit }[] = [];
    const store = vi.fn(async (target: string, init: RequestInit) => {
      reads.push({ url: target, init });
      return new Response(new Uint8Array([4, 5, 6, 7]), {
        status: 206,
        headers: { "accept-ranges": "bytes", "content-range": "bytes 4-7/12" },
      });
    });
    const proxied = vi.fn();

    const answer = await streams.serve(
      new Request(url, { headers: { range: "bytes=4-7" } }),
      authority(),
      proxied,
      store
    );

    expect(proxied).not.toHaveBeenCalled();
    expect(reads).toEqual([
      {
        url: signed,
        init: expect.objectContaining({
          credentials: "omit",
          headers: { range: "bytes=4-7" },
          redirect: "error",
        }),
      },
    ]);
    expect(answer.status).toBe(206);
    expect(answer.headers.get("content-length")).toBe("4");
    expect(new Uint8Array(await answer.arrayBuffer())).toEqual(
      new Uint8Array([4, 5, 6, 7])
    );
    expect(() =>
      streams.open({ url: "http://blobs.example.test/b/clip", type: "video/mp4" })
    ).toThrow();
  });

  it("refuses every read once its session is not the current one", async () => {
    const streams = new FileStreamRegistry();
    const url = streams.open({
      path,
      type: "video/mp4",
      lease: { ...sessionLease, generation: 2 },
    });
    const upstream = api();

    const answer = await streams.serve(new Request(url), authority(), upstream.fetch);

    expect(upstream.fetch).not.toHaveBeenCalled();
    expect(answer.ok).toBe(false);
    expect(await answer.arrayBuffer()).toHaveProperty("byteLength", 0);
  });

  it("asks the core for a file only it reaches, a range at a time, as the media element asks", async () => {
    const file = Uint8Array.of(0, 1, 2, 3, 4, 5, 6, 7, 8, 9);
    const asked: [string, number, number][] = [];
    const streams = new FileStreamRegistry(async (source, offset, length) => {
      asked.push([source, offset, length]);
      return {
        bytes: file.slice(offset, offset + length),
        type: "video/mp4",
        size: file.length,
      };
    });
    const source = JSON.stringify({ source: "attachment", message: "7:4" });
    const url = streams.open({ core: source, type: "video/mp4" });

    const answer = await streams.serve(
      new Request(url, { headers: { range: "bytes=2-5" } }),
      authority()
    );
    expect(asked).toEqual([[source, 2, 4]]);
    expect(answer.status).toBe(206);
    expect(answer.headers.get("content-range")).toBe("bytes 2-5/10");
    expect(answer.headers.get("content-length")).toBe("4");
    expect(answer.headers.get("content-type")).toBe("video/mp4");
    expect(new Uint8Array(await answer.arrayBuffer())).toEqual(
      Uint8Array.of(2, 3, 4, 5)
    );

    // From a point to the end: what the core gives of it.
    const rest = await streams.serve(
      new Request(url, { headers: { range: "bytes=8-" } }),
      authority()
    );
    expect(rest.headers.get("content-range")).toBe("bytes 8-9/10");
    // Past the end: none.
    const past = await streams.serve(
      new Request(url, { headers: { range: "bytes=20-" } }),
      authority()
    );
    expect(past.status).toBe(416);
  });

  it("knows nothing of a closed stream or a token it never gave", async () => {
    const streams = new FileStreamRegistry();
    const url = streams.open({ path, type: "audio/mpeg", lease: sessionLease });
    streams.close(url);
    const upstream = api();

    for (const asked of [url, "comma-file://stream/not-a-token"])
      expect(
        (await streams.serve(new Request(asked), authority(), upstream.fetch)).status
      ).toBe(404);
    expect(upstream.fetch).not.toHaveBeenCalled();
  });

  it("opens only a Comma API file, as audio, video or an image", () => {
    const streams = new FileStreamRegistry();
    expect(() =>
      streams.open({
        path: "https://elsewhere.test/x",
        type: "video/mp4",
        lease: sessionLease,
      })
    ).toThrow();
    expect(() =>
      streams.open({ path, type: "text/html", lease: sessionLease })
    ).toThrow();
  });

  it("saves a whole file into Downloads as it arrives, under the session, and passes on a refusal", async () => {
    const written: number[] = [];
    const save = vi.fn(
      async ({
        chunks,
        fileName,
      }: {
        chunks: AsyncIterable<Uint8Array>;
        fileName: string;
      }) => {
        for await (const chunk of chunks) written.push(...chunk);
        return {
          status: "saved" as const,
          downloadRef: `dnl1_${"a".repeat(43)}`,
          fileName,
        };
      }
    );
    const requests: Headers[] = [];
    const whole = vi.fn(async (_url: string, init: RequestInit) => {
      requests.push(new Headers(init.headers));
      return new Response(new Uint8Array([1, 2, 3]), { status: 200 });
    });

    expect(
      await saveApiFile(
        { path, fileName: "clip.mp4", lease: sessionLease },
        authority(),
        save,
        whole
      )
    ).toEqual({ downloadRef: `dnl1_${"a".repeat(43)}`, fileName: "clip.mp4" });
    expect(written).toEqual([1, 2, 3]);
    expect(requests[0]!.get("authorization")).toBe("Bearer main_secret");
    expect(requests[0]!.has("range")).toBe(false);

    const signed = vi.fn(async (_url: string, init: RequestInit) => {
      requests.push(new Headers(init.headers));
      return new Response(new Uint8Array([8, 9]), { status: 200 });
    });
    written.length = 0;
    expect(
      await saveApiFile(
        {
          url: "https://blobs.example.test/b/clip?X-Amz-Signature=s",
          fileName: "clip.mp4",
        },
        authority(),
        save,
        whole,
        signed
      )
    ).toEqual({ downloadRef: `dnl1_${"a".repeat(43)}`, fileName: "clip.mp4" });
    expect(written).toEqual([8, 9]);
    expect(requests[1]!.has("authorization")).toBe(false);

    const gone = vi.fn(async () =>
      Response.json({ error: "not_found" }, { status: 404 })
    );
    save.mockClear();
    expect(
      await saveApiFile(
        { path, fileName: "clip.mp4", lease: sessionLease },
        authority(),
        save,
        gone
      )
    ).toEqual({ status: 404, code: "not_found" });
    expect(save).not.toHaveBeenCalled();
  });
});

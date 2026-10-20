import { describe, expect, it, vi } from "vitest";
import {
  DriveStreamRegistry,
  type DriveStreamSource,
} from "../modules/synchronicity/stream";

const reference = { path: "recording.m4a", policy: "origin=laptop", space: "drive" };

function sourceOf(content: Buffer, root = { current: "root-one" }) {
  const read = vi.fn((_reference: unknown, start: number, length: number) =>
    (async function* () {
      // The node answers in several chunks; the body must join them.
      const bytes = content.subarray(start, start + length);
      const middle = Math.floor(bytes.byteLength / 2);
      yield bytes.subarray(0, middle);
      yield bytes.subarray(middle);
    })()
  );
  const source: DriveStreamSource = {
    resolve: async () => ({ contentRoot: root.current, size: content.byteLength }),
    read,
  };
  return { read, root, source };
}

function open(registry: DriveStreamRegistry, size: number) {
  return registry.open({
    contentRoot: "root-one",
    contentType: "audio/mp4",
    reference,
    size,
  });
}

describe("Drive media streams", () => {
  it("serves the whole object or exactly the requested ranges", async () => {
    const content = Buffer.from("0123456789abcdefghij");
    const { read, source } = sourceOf(content);
    const registry = new DriveStreamRegistry();
    const url = open(registry, content.byteLength);
    expect(url).toMatch(/^comma-drive:\/\/stream\/[0-9a-f-]{36}$/);

    const whole = await registry.serve(new Request(url), source);
    expect(whole.status).toBe(200);
    expect(whole.headers.get("content-type")).toBe("audio/mp4");
    expect(whole.headers.get("accept-ranges")).toBe("bytes");
    expect(await whole.text()).toBe("0123456789abcdefghij");

    const middle = await registry.serve(
      new Request(url, { headers: { range: "bytes=5-9" } }),
      source
    );
    expect(middle.status).toBe(206);
    expect(middle.headers.get("content-range")).toBe("bytes 5-9/20");
    expect(middle.headers.get("content-length")).toBe("5");
    expect(await middle.text()).toBe("56789");

    const tail = await registry.serve(
      new Request(url, { headers: { range: "bytes=-3" } }),
      source
    );
    expect(tail.headers.get("content-range")).toBe("bytes 17-19/20");
    expect(await tail.text()).toBe("hij");

    expect(read.mock.calls.map(([, start, length]) => [start, length])).toEqual([
      [0, 20],
      [5, 5],
      [17, 3],
    ]);
  });

  it("refuses unknown streams, impossible ranges and content replaced since opening", async () => {
    const content = Buffer.from("0123456789");
    const { read, root, source } = sourceOf(content);
    const registry = new DriveStreamRegistry();
    const url = open(registry, content.byteLength);

    const unknown = await registry.serve(
      new Request("comma-drive://stream/00000000-0000-0000-0000-000000000000"),
      source
    );
    expect(unknown.status).toBe(404);

    const beyond = await registry.serve(
      new Request(url, { headers: { range: "bytes=10-" } }),
      source
    );
    expect(beyond.status).toBe(416);
    expect(beyond.headers.get("content-range")).toBe("bytes */10");

    root.current = "root-two";
    const replaced = await registry.serve(new Request(url), source);
    expect(replaced.status).toBe(409);
    expect(read).not.toHaveBeenCalled();
  });

  it("fails the body when the content changes while a range is read", async () => {
    const content = Buffer.from("0123456789");
    const { root, source } = sourceOf(content);
    const registry = new DriveStreamRegistry();
    const url = open(registry, content.byteLength);
    const changing: DriveStreamSource = {
      ...source,
      read: (ref, start, length) => {
        root.current = "root-two";
        return source.read(ref, start, length);
      },
    };

    const response = await registry.serve(new Request(url), changing);

    expect(response.status).toBe(200);
    await expect(response.text()).rejects.toThrow();
  });
});

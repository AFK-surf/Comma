import { request as httpsRequest } from "node:https";
import { EventEmitter } from "node:events";
import { createServer } from "node:net";

import { beforeEach, describe, expect, it, vi } from "vitest";

type HttpsRequest = typeof import("node:https").request;

const { httpsRequestControl } = vi.hoisted(() => ({
  httpsRequestControl: {
    override: undefined as HttpsRequest | undefined,
  },
}));

vi.mock("node:https", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:https")>();
  return {
    ...actual,
    request: ((...args: unknown[]) =>
      Reflect.apply(
        httpsRequestControl.override ?? actual.request,
        undefined,
        args
      )) as HttpsRequest,
  };
});

vi.mock("electron", () => ({
  nativeImage: { createFromBuffer: vi.fn() },
}));

import {
  createPinnedHttpsRequestOptions,
  isPublicNetworkAddress,
  RecommendationMediaService,
} from "../modules/recommendation-media";

const PUBLIC_ADDRESS = { address: "8.8.8.8", family: 4 as const };

describe("RecommendationMediaService", () => {
  beforeEach(() => {
    httpsRequestControl.override = undefined;
    vi.restoreAllMocks();
  });

  it("returns only decoded, bounded PNG bytes from a pinned public HTTPS target", async () => {
    const inputPng = pngHeader(1, 1);
    const outputPng = pngHeader(1, 1);
    const resolveHostname = vi.fn(async () => [PUBLIC_ADDRESS]);
    const requestOnce = vi.fn(async () => ({
      bytes: inputPng,
      contentLength: inputPng.byteLength,
      contentType: "image/png; charset=binary",
      kind: "response" as const,
      status: 200,
    }));
    const service = new RecommendationMediaService({
      createRasterImage: () => ({
        getSize: () => ({ height: 1, width: 1 }),
        isEmpty: () => false,
        toPNG: () => outputPng,
      }),
      requestOnce,
      resolveHostname,
    });

    await expect(
      service.load({ url: "https://media.example/image.png" })
    ).resolves.toEqual({ pngImage: outputPng, status: "ready" });
    expect(resolveHostname).toHaveBeenCalledWith("media.example");
    expect(requestOnce).toHaveBeenCalledWith(
      expect.objectContaining({
        addresses: [PUBLIC_ADDRESS],
        url: new URL("https://media.example/image.png"),
      })
    );
  });

  it.each([
    "127.0.0.1",
    "169.254.169.254",
    "10.0.0.8",
    "192.168.1.8",
    "::1",
    "fc00::1",
    "fe80::1",
    "2001:db8::1",
  ])(
    "rejects non-public resolved address %s before issuing a request",
    async (address) => {
      const requestOnce = vi.fn();
      const service = new RecommendationMediaService({
        requestOnce,
        resolveHostname: async () => [
          { address, family: address.includes(":") ? (6 as const) : (4 as const) },
        ],
      });

      await expect(
        service.load({ url: "https://media.example/image.png" })
      ).resolves.toEqual({ status: "unavailable" });
      expect(requestOnce).not.toHaveBeenCalled();
    }
  );

  it("rejects a hostname if any returned address is private", async () => {
    const requestOnce = vi.fn();
    const service = new RecommendationMediaService({
      requestOnce,
      resolveHostname: async () => [PUBLIC_ADDRESS, { address: "10.0.0.7", family: 4 }],
    });

    await expect(
      service.load({ url: "https://media.example/image.png" })
    ).resolves.toEqual({ status: "unavailable" });
    expect(requestOnce).not.toHaveBeenCalled();
  });

  it("revalidates every redirect target and rejects a redirect to private network", async () => {
    const requestOnce = vi.fn(async () => ({
      kind: "redirect" as const,
      location: "https://169.254.169.254/latest/meta-data",
    }));
    const resolveHostname = vi
      .fn()
      .mockResolvedValueOnce([PUBLIC_ADDRESS])
      .mockResolvedValueOnce([{ address: "169.254.169.254", family: 4 }]);
    const service = new RecommendationMediaService({
      requestOnce,
      resolveHostname,
    });

    await expect(
      service.load({ url: "https://media.example/image.png" })
    ).resolves.toEqual({ status: "unavailable" });
    expect(resolveHostname).toHaveBeenNthCalledWith(2, "169.254.169.254");
    expect(requestOnce).toHaveBeenCalledTimes(1);
  });

  it("settles when DNS resolution stalls past the request deadline", async () => {
    const controller = new AbortController();
    const requestOnce = vi.fn();
    const service = new RecommendationMediaService({
      createAbortSignal: () => controller.signal,
      requestOnce,
      resolveHostname: () => new Promise(() => {}),
    });

    const result = service.load({ url: "https://media.example/image.png" });
    controller.abort();

    await expect(result).resolves.toEqual({ status: "unavailable" });
    expect(requestOnce).not.toHaveBeenCalled();
  });

  it("includes queue wait in each load deadline", async () => {
    const controllers = Array.from({ length: 7 }, () => new AbortController());
    let signalIndex = 0;
    const service = new RecommendationMediaService({
      createAbortSignal: () => controllers[signalIndex++]!.signal,
      requestOnce: vi.fn(),
      resolveHostname: () => new Promise(() => {}),
    });
    const loads = controllers.map((_controller, index) =>
      service.load({ url: `https://media-${index}.example/image.png` })
    );

    await Promise.resolve();
    controllers[6]!.abort();
    await expect(loads[6]).resolves.toEqual({ status: "unavailable" });

    for (const controller of controllers.slice(0, 6)) controller.abort();
    await expect(Promise.all(loads.slice(0, 6))).resolves.toEqual(
      Array.from({ length: 6 }, () => ({ status: "unavailable" }))
    );
  });

  it("keeps Node HTTPS in scalar lookup mode for its pinned address", async () => {
    const server = createServer((socket) => socket.destroy());
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });

    try {
      const address = server.address();
      if (!address || typeof address === "string")
        throw new Error("Missing test port.");
      const options = createPinnedHttpsRequestOptions(
        { address: "127.0.0.1", family: 4 },
        AbortSignal.timeout(2_000)
      );
      expect(options.autoSelectFamily).toBe(false);

      const error = await new Promise<NodeJS.ErrnoException>((resolve) => {
        const request = httpsRequest(
          `https://media.example:${address.port}/image.png`,
          options
        );
        request.once("error", resolve);
        request.end();
      });
      expect(error.code).not.toBe("ERR_INVALID_IP_ADDRESS");
    } finally {
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve()))
      );
    }
  });

  it("closes rejected response bodies before releasing the bounded load slot", async () => {
    const destroy = vi.fn();
    const response = Object.assign(new EventEmitter(), {
      destroy,
      headers: { "content-type": "text/html" },
      statusCode: 200,
    });
    const fakeRequest = Object.assign(new EventEmitter(), { end: vi.fn() });
    httpsRequestControl.override = ((...args: unknown[]) => {
      const onResponse = args.at(-1) as (value: typeof response) => void;
      queueMicrotask(() => onResponse(response));
      return fakeRequest;
    }) as unknown as HttpsRequest;
    const service = new RecommendationMediaService({
      resolveHostname: async () => [PUBLIC_ADDRESS],
    });

    await expect(
      service.load({ url: "https://media.example/image.png" })
    ).resolves.toEqual({ status: "unavailable" });
    expect(destroy).toHaveBeenCalledOnce();
  });

  it.each([
    {
      name: "non-image content type",
      response: {
        bytes: pngHeader(1, 1),
        contentType: "text/html",
        kind: "response" as const,
        status: 200,
      },
    },
    {
      name: "oversized response",
      response: {
        bytes: new Uint8Array(1024 * 1024 + 1),
        contentType: "image/png",
        kind: "response" as const,
        status: 200,
      },
    },
    {
      name: "invalid image bytes",
      response: {
        bytes: new TextEncoder().encode("not an image"),
        contentType: "image/png",
        kind: "response" as const,
        status: 200,
      },
    },
    {
      name: "oversized decoded dimensions",
      response: {
        bytes: pngHeader(2_048, 2_048),
        contentType: "image/png",
        kind: "response" as const,
        status: 200,
      },
    },
  ])(
    "degrades $name to unavailable without invoking the decoder",
    async ({ response }) => {
      const createRasterImage = vi.fn();
      const service = new RecommendationMediaService({
        createRasterImage,
        requestOnce: async () => response,
        resolveHostname: async () => [PUBLIC_ADDRESS],
      });

      await expect(
        service.load({ url: "https://media.example/image.png" })
      ).resolves.toEqual({ status: "unavailable" });
      expect(createRasterImage).not.toHaveBeenCalled();
    }
  );

  it.each([
    "http://media.example/image.png",
    "https://user:password@media.example/image.png",
    "https://localhost/image.png",
    "https://service.internal/image.png",
  ])("rejects unsafe target %s", async (url) => {
    const requestOnce = vi.fn();
    const resolveHostname = vi.fn(async () => [PUBLIC_ADDRESS]);
    const service = new RecommendationMediaService({
      requestOnce,
      resolveHostname,
    });

    await expect(service.load({ url })).resolves.toEqual({
      status: "unavailable",
    });
    expect(requestOnce).not.toHaveBeenCalled();
    expect(resolveHostname).not.toHaveBeenCalled();
  });
});

describe("isPublicNetworkAddress", () => {
  it.each(["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"])(
    "accepts public address %s",
    (address) => expect(isPublicNetworkAddress(address)).toBe(true)
  );

  it.each([
    "invalid",
    "0.0.0.0",
    "100.64.0.1",
    "198.51.100.2",
    "::2",
    "3fff::1",
    "4000::1",
    "5f00::1",
    "ff02::1",
  ])("rejects special-use address %s", (address) =>
    expect(isPublicNetworkAddress(address)).toBe(false)
  );
});

function pngHeader(width: number, height: number) {
  const bytes = Buffer.alloc(33);
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes);
  bytes.writeUInt32BE(13, 8);
  bytes.write("IHDR", 12, "ascii");
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  bytes[24] = 8;
  bytes[25] = 6;
  bytes[26] = 0;
  bytes[27] = 0;
  bytes[28] = 0;
  return bytes;
}

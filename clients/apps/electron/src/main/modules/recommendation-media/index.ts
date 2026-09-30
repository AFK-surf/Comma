import { lookup as dnsLookup } from "node:dns/promises";
import { request as httpsRequest, type RequestOptions } from "node:https";
import { BlockList, isIP } from "node:net";

import type {
  RecommendationMediaLoadInput,
  RecommendationMediaLoadResult,
} from "@comma/native-bridge";
import { nativeImage } from "electron";

const MAX_INPUT_BYTES = 1024 * 1024;
const MAX_OUTPUT_BYTES = 1024 * 1024;
const MAX_IMAGE_DIMENSION = 2_048;
const MAX_IMAGE_PIXELS = 1_048_576;
const MAX_REDIRECTS = 3;
const REQUEST_TIMEOUT_MS = 5_000;
const MAX_ACTIVE_LOADS = 6;
const MAX_QUEUED_LOADS = 24;
const JPEG_HEADER_SCAN_MAX_BYTES = 1024 * 1024;
const JPEG_HEADER_SCAN_MAX_SEGMENTS = 1_024;
const ALLOWED_MEDIA_TYPES = new Set(["image/jpeg", "image/png"]);

export type ResolvedAddress = {
  address: string;
  family: 4 | 6;
};

type ResolveHostname = (hostname: string) => Promise<ResolvedAddress[]>;

type RemoteMediaResponse =
  | { kind: "redirect"; location: string }
  | {
      bytes?: Uint8Array | undefined;
      contentLength?: number | undefined;
      contentType?: string | undefined;
      kind: "response";
      status: number;
    };

type RequestOnce = (input: {
  addresses: readonly ResolvedAddress[];
  signal: AbortSignal;
  url: URL;
}) => Promise<RemoteMediaResponse>;

type RasterImage = {
  getSize(): { height: number; width: number };
  isEmpty(): boolean;
  toPNG(): Uint8Array;
};

type CreateRasterImage = (bytes: Uint8Array) => RasterImage;
type CreateAbortSignal = () => AbortSignal;

export interface RecommendationMediaProvider {
  load(input: RecommendationMediaLoadInput): Promise<RecommendationMediaLoadResult>;
}

/**
 * Main owns remote recommendation media intake. Renderer code receives only a
 * bounded, decoded PNG and never receives permission to fetch the source URL.
 */
export class RecommendationMediaService implements RecommendationMediaProvider {
  readonly #createRasterImage: CreateRasterImage;
  readonly #createAbortSignal: CreateAbortSignal;
  readonly #pool = new BoundedWorkPool(MAX_ACTIVE_LOADS, MAX_QUEUED_LOADS);
  readonly #requestOnce: RequestOnce;
  readonly #resolveHostname: ResolveHostname;

  constructor({
    createAbortSignal = () => AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    createRasterImage = (bytes) => nativeImage.createFromBuffer(Buffer.from(bytes)),
    requestOnce = requestPinnedHttps,
    resolveHostname = resolveHostnameAddresses,
  }: {
    createAbortSignal?: CreateAbortSignal;
    createRasterImage?: CreateRasterImage;
    requestOnce?: RequestOnce;
    resolveHostname?: ResolveHostname;
  } = {}) {
    this.#createAbortSignal = createAbortSignal;
    this.#createRasterImage = createRasterImage;
    this.#requestOnce = requestOnce;
    this.#resolveHostname = resolveHostname;
  }

  async load(
    input: RecommendationMediaLoadInput
  ): Promise<RecommendationMediaLoadResult> {
    const signal = this.#createAbortSignal();
    try {
      return await this.#pool.run(async () => {
        const response = await this.#loadRemoteMedia(input.url, signal);
        if (signal.aborted) return unavailable();
        if (response.status !== 200) return unavailable();

        const contentType = normalizeMediaType(response.contentType);
        if (!contentType || !ALLOWED_MEDIA_TYPES.has(contentType)) {
          return unavailable();
        }
        if (
          response.contentLength !== undefined &&
          (!Number.isSafeInteger(response.contentLength) ||
            response.contentLength <= 0 ||
            response.contentLength > MAX_INPUT_BYTES)
        ) {
          return unavailable();
        }
        const bytes = response.bytes;
        if (!bytes || bytes.byteLength === 0 || bytes.byteLength > MAX_INPUT_BYTES) {
          return unavailable();
        }

        const header = inspectRasterHeader(bytes, contentType);
        if (!header || !validImageDimensions(header.width, header.height)) {
          return unavailable();
        }

        const image = this.#createRasterImage(bytes);
        if (signal.aborted) return unavailable();
        if (image.isEmpty()) return unavailable();
        const size = image.getSize();
        if (!validImageDimensions(size.width, size.height)) return unavailable();

        const pngImage = image.toPNG();
        if (
          !(pngImage instanceof Uint8Array) ||
          pngImage.byteLength === 0 ||
          pngImage.byteLength > MAX_OUTPUT_BYTES
        ) {
          return unavailable();
        }
        return { pngImage, status: "ready" };
      }, signal);
    } catch {
      return unavailable();
    }
  }

  async #loadRemoteMedia(urlValue: string, signal: AbortSignal) {
    let url = parseSafeHttpsUrl(urlValue);

    for (let redirectCount = 0; ; redirectCount += 1) {
      const hostname = normalizedHostname(url);
      if (isReservedHostname(hostname)) throw mediaUnavailable();
      const addresses = await raceAbort(this.#resolveHostname(hostname), signal);
      if (
        addresses.length === 0 ||
        addresses.some(
          ({ address, family }) =>
            (family !== 4 && family !== 6) || !isPublicNetworkAddress(address)
        )
      ) {
        throw mediaUnavailable();
      }

      const response = await this.#requestOnce({ addresses, signal, url });
      if (response.kind === "response") return response;
      if (redirectCount >= MAX_REDIRECTS) throw mediaUnavailable();
      url = parseSafeHttpsUrl(new URL(response.location, url).href);
    }
  }
}

function raceAbort<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(mediaUnavailable());
  return new Promise<T>((resolve, reject) => {
    const abort = () => {
      cleanup();
      reject(mediaUnavailable());
    };
    const cleanup = () => signal.removeEventListener("abort", abort);
    signal.addEventListener("abort", abort, { once: true });
    promise.then(
      (value) => {
        cleanup();
        resolve(value);
      },
      () => {
        cleanup();
        reject(mediaUnavailable());
      }
    );
  });
}

function unavailable(): RecommendationMediaLoadResult {
  return { status: "unavailable" };
}

async function resolveHostnameAddresses(hostname: string): Promise<ResolvedAddress[]> {
  const addresses = await dnsLookup(hostname, { all: true, verbatim: true });
  return addresses.flatMap(({ address, family }) =>
    family === 4 || family === 6 ? [{ address, family }] : []
  );
}

function requestPinnedHttps({
  addresses,
  signal,
  url,
}: {
  addresses: readonly ResolvedAddress[];
  signal: AbortSignal;
  url: URL;
}): Promise<RemoteMediaResponse> {
  const pinned = addresses[0];
  if (!pinned) return Promise.reject(mediaUnavailable());

  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (result: RemoteMediaResponse) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };
    const fail = () => {
      if (settled) return;
      settled = true;
      reject(mediaUnavailable());
    };
    const request = httpsRequest(
      url,
      createPinnedHttpsRequestOptions(pinned, signal),
      (response) => {
        const status = response.statusCode ?? 0;
        const location = firstHeaderValue(response.headers.location);
        if ([301, 302, 303, 307, 308].includes(status) && location) {
          finish({ kind: "redirect", location });
          response.destroy();
          return;
        }

        const contentType = firstHeaderValue(response.headers["content-type"]);
        const contentLength = parseContentLength(
          firstHeaderValue(response.headers["content-length"])
        );
        if (
          status !== 200 ||
          !ALLOWED_MEDIA_TYPES.has(normalizeMediaType(contentType) ?? "") ||
          contentLength === null ||
          (contentLength !== undefined && contentLength > MAX_INPUT_BYTES)
        ) {
          finish({
            ...(contentLength === null || contentLength === undefined
              ? {}
              : { contentLength }),
            ...(contentType ? { contentType } : {}),
            kind: "response",
            status,
          });
          response.destroy();
          return;
        }

        const chunks: Buffer[] = [];
        let totalBytes = 0;
        response.on("data", (chunk: Buffer | Uint8Array) => {
          if (settled) return;
          const bytes = Buffer.from(chunk);
          totalBytes += bytes.byteLength;
          if (totalBytes > MAX_INPUT_BYTES) {
            response.destroy(mediaUnavailable());
            fail();
            return;
          }
          chunks.push(bytes);
        });
        response.once("end", () => {
          finish({
            bytes: Buffer.concat(chunks, totalBytes),
            ...(contentLength === undefined ? {} : { contentLength }),
            ...(contentType ? { contentType } : {}),
            kind: "response",
            status,
          });
        });
        response.once("aborted", fail);
        response.once("error", fail);
      }
    );
    request.once("error", fail);
    request.end();
  });
}

export function createPinnedHttpsRequestOptions(
  pinned: ResolvedAddress,
  signal: AbortSignal
): RequestOptions & { autoSelectFamily: false } {
  return {
    // Node 20+ may otherwise invoke a custom lookup with `{ all: true }` for
    // auto-family selection. This request intentionally pins one vetted
    // address, so keep the scalar lookup contract explicit.
    autoSelectFamily: false,
    headers: {
      Accept: "image/png,image/jpeg",
      "Cache-Control": "no-store",
    },
    lookup: (_hostname, _options, callback) =>
      callback(null, pinned.address, pinned.family),
    signal,
  };
}

function firstHeaderValue(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] : value;
}

function parseContentLength(value: string | undefined): number | null | undefined {
  if (value === undefined) return undefined;
  if (!/^\d+$/.test(value)) return null;
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function normalizeMediaType(value: string | undefined) {
  return value?.split(";", 1)[0]?.trim().toLowerCase();
}

function parseSafeHttpsUrl(value: string) {
  const url = new URL(value);
  if (
    url.protocol !== "https:" ||
    url.username.length > 0 ||
    url.password.length > 0 ||
    url.href.length > 8_192
  ) {
    throw mediaUnavailable();
  }
  return url;
}

function normalizedHostname(url: URL) {
  const hostname = url.hostname.toLowerCase();
  return hostname.startsWith("[") && hostname.endsWith("]")
    ? hostname.slice(1, -1)
    : hostname;
}

function isReservedHostname(hostname: string) {
  return (
    hostname === "localhost" ||
    hostname.endsWith(".localhost") ||
    hostname.endsWith(".local") ||
    hostname.endsWith(".internal") ||
    hostname === "home.arpa" ||
    hostname.endsWith(".home.arpa")
  );
}

const blockedIpv4 = new BlockList();
for (const [network, prefix] of [
  ["0.0.0.0", 8],
  ["10.0.0.0", 8],
  ["100.64.0.0", 10],
  ["127.0.0.0", 8],
  ["169.254.0.0", 16],
  ["172.16.0.0", 12],
  ["192.0.0.0", 24],
  ["192.0.2.0", 24],
  ["192.88.99.0", 24],
  ["192.168.0.0", 16],
  ["198.18.0.0", 15],
  ["198.51.100.0", 24],
  ["203.0.113.0", 24],
  ["224.0.0.0", 4],
  ["240.0.0.0", 4],
] as const) {
  blockedIpv4.addSubnet(network, prefix, "ipv4");
}

const blockedIpv6 = new BlockList();
for (const [network, prefix] of [
  ["::", 128],
  ["::1", 128],
  ["::ffff:0:0", 96],
  ["64:ff9b::", 96],
  ["64:ff9b:1::", 48],
  ["100::", 64],
  ["2001::", 23],
  ["2001:db8::", 32],
  ["2002::", 16],
  ["3fff::", 20],
  ["fc00::", 7],
  ["fe80::", 10],
  ["fec0::", 10],
  ["ff00::", 8],
] as const) {
  blockedIpv6.addSubnet(network, prefix, "ipv6");
}

const publicIpv6 = new BlockList();
publicIpv6.addSubnet("2000::", 3, "ipv6");

export function isPublicNetworkAddress(address: string) {
  const family = isIP(address);
  if (family === 4) return !blockedIpv4.check(address, "ipv4");
  if (family === 6) {
    return publicIpv6.check(address, "ipv6") && !blockedIpv6.check(address, "ipv6");
  }
  return false;
}

function inspectRasterHeader(bytes: Uint8Array, contentType: string) {
  const buffer = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return contentType === "image/png"
    ? inspectPngHeader(buffer)
    : contentType === "image/jpeg"
      ? inspectJpegHeader(buffer)
      : undefined;
}

function inspectPngHeader(bytes: Buffer) {
  const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (
    bytes.byteLength < 33 ||
    !bytes.subarray(0, signature.byteLength).equals(signature) ||
    bytes.readUInt32BE(8) !== 13 ||
    bytes.toString("ascii", 12, 16) !== "IHDR"
  ) {
    return undefined;
  }
  const bitDepth = bytes[24];
  const colorType = bytes[25];
  const validBitDepth =
    (colorType === 0 && [1, 2, 4, 8, 16].includes(bitDepth ?? -1)) ||
    (colorType === 2 && [8, 16].includes(bitDepth ?? -1)) ||
    (colorType === 3 && [1, 2, 4, 8].includes(bitDepth ?? -1)) ||
    ((colorType === 4 || colorType === 6) && [8, 16].includes(bitDepth ?? -1));
  if (
    !validBitDepth ||
    bytes[26] !== 0 ||
    bytes[27] !== 0 ||
    (bytes[28] !== 0 && bytes[28] !== 1)
  ) {
    return undefined;
  }
  return { height: bytes.readUInt32BE(20), width: bytes.readUInt32BE(16) };
}

function inspectJpegHeader(bytes: Buffer) {
  if (bytes.byteLength < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) {
    return undefined;
  }
  const limit = Math.min(bytes.byteLength, JPEG_HEADER_SCAN_MAX_BYTES);
  let offset = 2;
  let segments = 0;
  while (offset < limit && segments < JPEG_HEADER_SCAN_MAX_SEGMENTS) {
    if (bytes[offset] !== 0xff) return undefined;
    while (offset < limit && bytes[offset] === 0xff) offset += 1;
    if (offset >= limit) return undefined;
    const marker = bytes[offset++]!;
    segments += 1;
    if (marker === 0x00 || marker === 0xd9 || marker === 0xda) return undefined;
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      continue;
    }
    if (offset + 2 > limit) return undefined;
    const segmentLength = bytes.readUInt16BE(offset);
    if (segmentLength < 2 || offset + segmentLength > limit) return undefined;
    if (marker === 0xc0 || marker === 0xc2) {
      if (segmentLength < 11 || bytes[offset + 2] !== 8) return undefined;
      const height = bytes.readUInt16BE(offset + 3);
      const width = bytes.readUInt16BE(offset + 5);
      const components = bytes[offset + 7];
      if (
        components === undefined ||
        components < 1 ||
        components > 4 ||
        segmentLength !== 8 + 3 * components
      ) {
        return undefined;
      }
      return { height, width };
    }
    if (
      marker === 0xc1 ||
      marker === 0xc3 ||
      (marker >= 0xc5 && marker <= 0xc7) ||
      (marker >= 0xc9 && marker <= 0xcb) ||
      (marker >= 0xcd && marker <= 0xcf)
    ) {
      return undefined;
    }
    offset += segmentLength;
  }
  return undefined;
}

function validImageDimensions(width: number, height: number) {
  return (
    Number.isSafeInteger(width) &&
    Number.isSafeInteger(height) &&
    width > 0 &&
    height > 0 &&
    width <= MAX_IMAGE_DIMENSION &&
    height <= MAX_IMAGE_DIMENSION &&
    width * height <= MAX_IMAGE_PIXELS
  );
}

type QueuedMediaWork = {
  onAbort: () => void;
  reject: (error: Error) => void;
  resolve: (value: RecommendationMediaLoadResult) => void;
  signal: AbortSignal;
  task: () => Promise<RecommendationMediaLoadResult>;
};

class BoundedWorkPool {
  #active = 0;
  readonly #maxActive: number;
  readonly #maxQueued: number;
  readonly #queue: QueuedMediaWork[] = [];

  constructor(maxActive: number, maxQueued: number) {
    this.#maxActive = maxActive;
    this.#maxQueued = maxQueued;
  }

  run(task: () => Promise<RecommendationMediaLoadResult>, signal: AbortSignal) {
    if (signal.aborted) return Promise.reject(mediaUnavailable());
    if (this.#active < this.#maxActive) return this.#start(task);
    if (this.#queue.length >= this.#maxQueued) {
      return Promise.reject(mediaUnavailable());
    }
    return new Promise<RecommendationMediaLoadResult>((resolve, reject) => {
      const work: QueuedMediaWork = {
        onAbort: () => {
          const index = this.#queue.indexOf(work);
          if (index < 0) return;
          this.#queue.splice(index, 1);
          reject(mediaUnavailable());
        },
        reject,
        resolve,
        signal,
        task,
      };
      signal.addEventListener("abort", work.onAbort, { once: true });
      this.#queue.push(work);
    });
  }

  async #start(task: () => Promise<RecommendationMediaLoadResult>) {
    this.#active += 1;
    try {
      return await task();
    } finally {
      this.#active -= 1;
      this.#drain();
    }
  }

  #drain() {
    while (this.#active < this.#maxActive) {
      const next = this.#queue.shift();
      if (!next) return;
      next.signal.removeEventListener("abort", next.onAbort);
      if (next.signal.aborted) {
        next.reject(mediaUnavailable());
        continue;
      }
      void this.#start(next.task).then(next.resolve, next.reject);
    }
  }
}

function mediaUnavailable() {
  return new Error("Routine media is unavailable.");
}

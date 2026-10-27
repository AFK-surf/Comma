import { randomUUID } from "node:crypto";
import { net } from "electron";
import { sessionPresenceExpectationHeader } from "@comma/session-contract";
import type {
  SavedStream,
  UtilityFileRead,
  UtilityStreamRead,
} from "@comma/core/utility-protocol";
import type { FilesSaveDownloadResult } from "@comma/native-bridge";
import { proxyCommaApiRequest, type CommaApiCredentialAuthority } from "../../protocol";

/**
 * Files a window's media element plays (the core's `fileStream`): the core opens one for a file a window shows, and the
 * element reads `comma-file://stream/<token>` in the ranges it asks for, so a file of any size plays without its bytes
 * crossing IPC. A Comma API file is read through the `/v1` proxy under the session the core opened the stream for:
 * Main adds the credential it alone holds and refuses the read once that session is not the current one. A signed URL
 * (an attachment's, from the blob store) is its own authority: Main reads it with no credential. A file only the core
 * reaches (`core`: a Task's a station hosts) Main asks the core for, a range at a time (`files.readRange`, at most its
 * station's part). The token is the window's only handle on the stream; it names no path and carries no credential.
 */
export const fileStreamScheme = "comma-file";

/** Streams kept at once, the oldest forgotten first. The core closes each once no window shows its file. */
const MAX_OPEN_STREAMS = 64;
const MEDIA_TYPE = /^(?:audio|video|image)\/[a-z0-9][a-z0-9.+-]*$/;
const CONTENT_RANGE = /^bytes (\d+)-(\d+)\/\d+$/;

type OpenStream = UtilityStreamRead & { type: string };

/** A range of a file only the core reaches: up to `length` bytes from `offset`, their type, and the whole size. */
export type CoreRange = (
  source: string,
  offset: number,
  length: number
) => Promise<{ bytes: Uint8Array; type: string; size: number }>;

const RANGE = /^bytes=(\d+)-(\d*)$/;
/** The most of a file one range asked of the core takes: a station's part. */
const CORE_PART = 8 * 1024 * 1024;

/** The fetch a signed URL is read with: no credential, no redirect. */
type UrlFetch = (url: string, init: RequestInit) => Promise<Response>;

export class FileStreamRegistry {
  readonly #streams = new Map<string, OpenStream>();
  readonly #coreRange: CoreRange | undefined;

  constructor(coreRange?: CoreRange) {
    this.#coreRange = coreRange;
  }

  /** A URL for the API's GET `path` played as `type` under `lease`, or for a signed `url`. */
  open(stream: OpenStream): string {
    if ("core" in stream) {
      if (!this.#coreRange) throw new Error("No core reads files here.");
    } else checkRead(stream);
    if (!MEDIA_TYPE.test(stream.type))
      throw new Error("Only audio, video or images stream.");
    const token = randomUUID();
    this.#streams.set(token, stream);
    while (this.#streams.size > MAX_OPEN_STREAMS) {
      this.#streams.delete(this.#streams.keys().next().value!);
    }
    return `${fileStreamScheme}://stream/${token}`;
  }

  close(url: string): void {
    this.#streams.delete(tokenOf(url));
  }

  async serve(
    request: Request,
    authority: CommaApiCredentialAuthority,
    fetchImpl?: Parameters<typeof proxyCommaApiRequest>[3],
    urlFetch?: UrlFetch
  ): Promise<Response> {
    const stream = this.#streams.get(tokenOf(request.url));
    if (!stream) return new Response(null, { status: 404 });
    if (request.method !== "GET") return new Response(null, { status: 405 });
    if ("core" in stream)
      return this.#serveCore(stream.core, stream.type, request.headers.get("range"));
    const answer = await readFile(
      stream,
      request.headers.get("range"),
      authority,
      fetchImpl,
      urlFetch
    );
    // The token is the authority; CORS lets a video frame reach a canvas untainted.
    const out = new Headers({
      "access-control-allow-origin": "*",
      "cache-control": "no-store",
      // The type is the file's sender's: opened as a page, it runs no script.
      "content-security-policy": "sandbox",
      "x-content-type-options": "nosniff",
    });
    const contentRange = answer.headers.get("content-range");
    if (contentRange) out.set("content-range", contentRange);
    if (answer.status !== 200 && answer.status !== 206) {
      await answer.body?.cancel();
      return new Response(null, { headers: out, status: answer.status });
    }
    out.set("content-type", stream.type);
    out.set("accept-ranges", answer.headers.get("accept-ranges") ?? "none");
    // The proxy passes no length; a range's follows from what it answers.
    const span = contentRange?.match(CONTENT_RANGE);
    if (span) out.set("content-length", String(Number(span[2]) - Number(span[1]) + 1));
    else if (answer.headers.has("content-length"))
      out.set("content-length", answer.headers.get("content-length")!);
    return new Response(answer.body, { headers: out, status: answer.status });
  }

  /** The range a media element asks of a file only the core reaches (from its start when it names none). */
  async #serveCore(
    source: string,
    type: string,
    range: string | null
  ): Promise<Response> {
    const asked = range ? RANGE.exec(range.trim()) : null;
    if (range && !asked) return new Response(null, { status: 416 });
    const offset = asked ? Number(asked[1]) : 0;
    const end = asked?.[2] ? Number(asked[2]) : offset + CORE_PART - 1;
    if (!this.#coreRange || end < offset) return new Response(null, { status: 416 });
    let part: Awaited<ReturnType<CoreRange>>;
    try {
      part = await this.#coreRange(
        source,
        offset,
        Math.min(end - offset + 1, CORE_PART)
      );
    } catch {
      return new Response(null, { status: 502 });
    }
    const headers = new Headers({
      "access-control-allow-origin": "*",
      "cache-control": "no-store",
      "content-security-policy": "sandbox",
      "x-content-type-options": "nosniff",
      "accept-ranges": "bytes",
      "content-type": type,
    });
    if (part.bytes.byteLength === 0) {
      headers.set("content-range", `bytes */${part.size}`);
      return new Response(null, { headers, status: 416 });
    }
    headers.set(
      "content-range",
      `bytes ${offset}-${offset + part.bytes.byteLength - 1}/${part.size}`
    );
    headers.set("content-length", String(part.bytes.byteLength));
    return new Response(part.bytes as Uint8Array<ArrayBuffer>, {
      headers,
      status: 206,
    });
  }
}

/** A file's bytes (one `range` of them when given): through the `/v1` proxy, or from its signed URL. */
function readFile(
  read: UtilityFileRead,
  range: string | null,
  authority: CommaApiCredentialAuthority,
  fetchImpl?: Parameters<typeof proxyCommaApiRequest>[3],
  urlFetch?: UrlFetch
): Promise<Response> {
  return "url" in read
    ? readSignedUrl(read.url, range, urlFetch)
    : readApiFile({ ...read, range }, authority, fetchImpl);
}

/**
 * A signed URL's bytes, read with no credential and no redirect followed. Letting the answer go (its body cancelled)
 * ends the request: cancelling a `net.fetch` body alone leaves its connection open.
 */
async function readSignedUrl(
  url: string,
  range: string | null,
  urlFetch: UrlFetch = (target, init) =>
    net.fetch(target, { ...init, bypassCustomProtocolHandlers: true } as RequestInit)
): Promise<Response> {
  const upstream = new AbortController();
  const answer = await urlFetch(url, {
    credentials: "omit",
    headers: range ? { range } : {},
    redirect: "error",
    signal: upstream.signal,
  });
  if (!answer.body) return answer;
  const reader = answer.body.getReader();
  const body = new ReadableStream<Uint8Array>({
    async pull(controller) {
      const next = await reader.read();
      if (next.done) controller.close();
      else controller.enqueue(next.value);
    },
    async cancel(reason) {
      upstream.abort(reason);
      await reader.cancel(reason).catch(() => undefined);
    },
  });
  return new Response(body, { headers: answer.headers, status: answer.status });
}

/**
 * The API's GET `path` (one `range` of it when given) as the `/v1` proxy answers it under `lease`: the credential added,
 * refused once that session is not the current one.
 */
export function readApiFile(
  {
    path,
    lease,
    range,
  }: Extract<UtilityFileRead, { path: string }> & { range?: string | null },
  authority: CommaApiCredentialAuthority,
  fetchImpl?: Parameters<typeof proxyCommaApiRequest>[3]
): Promise<Response> {
  const headers = new Headers({
    [sessionPresenceExpectationHeader]: JSON.stringify({
      authorityInstanceId: lease.authorityInstanceId,
      expectedAudience: lease.audience,
      expectedSessionId: lease.sessionId,
      generation: lease.generation,
    }),
  });
  if (range) headers.set("range", range);
  return proxyCommaApiRequest(
    new Request(new URL(path, "https://core.invalid"), { headers }),
    new URL(path, "assets://."),
    authority,
    fetchImpl
  );
}

/**
 * A file written into the Downloads folder as `fileName` as it arrives (`save`): the API's GET `path` read under
 * `lease`, or a signed `url`. The saved file's handle and the name it took, the server's refusal (its status and
 * `{error}` code), or null when it was not written. A read that breaks off fails the write, and no partial file is kept.
 */
export async function saveApiFile(
  input: UtilityFileRead & { fileName: string },
  authority: CommaApiCredentialAuthority,
  save: (file: {
    chunks: AsyncIterable<Uint8Array>;
    fileName: string;
  }) => Promise<FilesSaveDownloadResult>,
  fetchImpl?: Parameters<typeof proxyCommaApiRequest>[3],
  urlFetch?: UrlFetch
): Promise<SavedStream> {
  checkRead(input);
  const answer = await readFile(input, null, authority, fetchImpl, urlFetch);
  if (answer.status !== 200 || !answer.body) {
    const body: unknown = await answer.json().catch(() => null);
    const code =
      body &&
      typeof body === "object" &&
      "error" in body &&
      typeof body.error === "string"
        ? body.error
        : "unavailable";
    return { status: answer.status, code };
  }
  const saved = await save({ chunks: answer.body, fileName: input.fileName });
  return saved.status === "saved"
    ? { downloadRef: saved.downloadRef, fileName: saved.fileName }
    : null;
}

/** A Comma API file, or a signed URL over HTTPS (HTTP only on this machine: a development store). */
function checkRead(read: UtilityFileRead): void {
  if ("url" in read) {
    const url = URL.canParse(read.url) ? new URL(read.url) : null;
    const loopback = url?.hostname === "127.0.0.1" || url?.hostname === "localhost";
    if (!url || !(url.protocol === "https:" || (url.protocol === "http:" && loopback)))
      throw new Error("Only an HTTPS URL streams.");
  } else if (!read.path.startsWith("/v1/")) {
    throw new Error("Only a Comma API file streams.");
  }
}

function tokenOf(url: string): string {
  const parsed = URL.canParse(url) ? new URL(url) : null;
  return parsed?.protocol === `${fileStreamScheme}:` && parsed.hostname === "stream"
    ? parsed.pathname.slice(1)
    : "";
}

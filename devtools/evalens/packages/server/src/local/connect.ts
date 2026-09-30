import type {
  IncomingHttpHeaders,
  IncomingMessage,
  OutgoingHttpHeader,
  OutgoingHttpHeaders,
  ServerResponse,
} from "node:http";
import { Readable, Writable } from "node:stream";
import type { ReadableStreamDefaultReader } from "node:stream/web";

type NextFunction = (error?: Error) => void;
type Middleware = (
  request: IncomingMessage,
  response: ServerResponse,
  next: NextFunction
) => void;

export function connectToFetch(middleware: Middleware) {
  return async (request: Request): Promise<Response> => {
    const incoming = new FetchIncomingMessage(request);
    const outgoing = new FetchServerResponse(incoming);
    let resolveNotFound: (response: Response) => void = () => {};
    const notFound = new Promise<Response>((resolve) => {
      resolveNotFound = resolve;
    });
    let rejectMiddleware: (error: Error) => void = () => {};
    const middlewareFailure = new Promise<Response>((_resolve, reject) => {
      rejectMiddleware = reject;
    });

    middleware(
      incoming as unknown as IncomingMessage,
      outgoing as unknown as ServerResponse,
      (error) => {
        if (error) {
          rejectMiddleware(error);
          outgoing.destroy();
          return;
        }
        resolveNotFound(new Response(null, { status: 404 }));
      }
    );

    return Promise.race([middlewareFailure, outgoing.response, notFound]);
  };
}

class FetchIncomingMessage extends Readable {
  readonly headers: IncomingHttpHeaders;
  readonly rawHeaders: string[];
  readonly method: string;
  readonly url: string;
  readonly originalUrl: string;
  readonly httpVersion: string;
  readonly httpVersionMajor: number;
  readonly httpVersionMinor: number;
  readonly socket = { remoteAddress: "127.0.0.1" };
  complete = false;
  private bodyReader: ReadableStreamDefaultReader<Uint8Array> | null;

  constructor(request: Request) {
    super();
    const url = new URL(request.url);
    this.url = `${url.pathname}${url.search}`;
    this.originalUrl = this.url;
    this.method = request.method;
    this.headers = Object.fromEntries(request.headers.entries());
    this.rawHeaders = [...request.headers.entries()].flat();
    this.httpVersion = request.headers.get("http-version") ?? "1.1";
    this.httpVersionMajor = Number.parseInt(this.httpVersion.split(".")[0] ?? "1");
    this.httpVersionMinor = Number.parseInt(this.httpVersion.split(".")[1] ?? "1");
    this.bodyReader = request.body?.getReader() ?? null;
  }

  override _read(): void {
    if (!this.bodyReader) {
      this.complete = true;
      this.push(null);
      return;
    }
    this.bodyReader.read().then(
      ({ done, value }) => {
        if (done) {
          this.complete = true;
          this.push(null);
        } else {
          this.push(value);
        }
      },
      (error) => this.destroy(toError(error))
    );
  }

  override _destroy(
    error: Error | null,
    callback: (error?: Error | null) => void
  ): void {
    const reader = this.bodyReader;
    this.bodyReader = null;
    if (!reader) {
      callback(error);
      return;
    }
    reader.cancel(error ?? undefined).then(() => callback(error), callback);
  }
}

class FetchServerResponse extends Writable {
  readonly response: Promise<Response>;
  statusCode = 200;
  statusMessage = "OK";
  headersSent = false;
  private readonly headers = new Headers();
  private readonly stream = new TransformStream<Uint8Array, Uint8Array>();
  private readonly writer = this.stream.writable.getWriter();
  private resolveResponse: (response: Response) => void = () => {};
  private responseResolved = false;

  constructor(readonly req: FetchIncomingMessage) {
    super();
    this.response = new Promise((resolve) => {
      this.resolveResponse = resolve;
    });
  }

  setHeader(name: string, value: number | string | readonly string[]): this {
    this.headers.delete(name);
    if (Array.isArray(value)) {
      for (const entry of value) this.headers.append(name, entry);
    } else {
      this.headers.set(name, String(value));
    }
    return this;
  }

  appendHeader(name: string, value: number | string | readonly string[]): this {
    if (Array.isArray(value)) {
      for (const entry of value) this.headers.append(name, entry);
    } else {
      this.headers.append(name, String(value));
    }
    return this;
  }

  removeHeader(name: string): void {
    this.headers.delete(name);
  }

  hasHeader(name: string): boolean {
    return this.headers.has(name);
  }

  getHeader(name: string): string | undefined {
    return this.headers.get(name) ?? undefined;
  }

  getHeaderNames(): string[] {
    return [...this.headers.keys()];
  }

  getHeaders(): OutgoingHttpHeaders {
    return Object.fromEntries(this.headers.entries());
  }

  flushHeaders(): void {
    this.headersSent = true;
    this.ensureResponse(true);
  }

  writeHead(
    statusCode: number,
    headers?: OutgoingHttpHeaders | OutgoingHttpHeader[]
  ): this;
  writeHead(
    statusCode: number,
    statusMessage?: string,
    headers?: OutgoingHttpHeaders | OutgoingHttpHeader[]
  ): this;
  writeHead(
    statusCode: number,
    statusMessage?: string | OutgoingHttpHeaders | OutgoingHttpHeader[],
    headers?: OutgoingHttpHeaders | OutgoingHttpHeader[]
  ): this {
    if (typeof statusMessage !== "string") {
      headers = statusMessage;
      statusMessage = undefined;
    }
    if (this.writableFinished) throw new Error("response is already finished");
    if (this.headersSent) throw new Error("response headers were already sent");

    this.statusCode = statusCode;
    this.statusMessage = statusMessage ?? this.statusMessage;
    if (Array.isArray(headers)) {
      if (headers.length % 2 !== 0) {
        throw new Error("response headers must contain key-value pairs");
      }
      for (let index = 0; index < headers.length; index += 2) {
        this.removeHeader(String(headers[index]));
      }
      for (let index = 0; index < headers.length; index += 2) {
        this.appendHeader(String(headers[index]), headers[index + 1]!);
      }
    } else if (headers) {
      for (const [name, value] of Object.entries(headers)) {
        if (value !== undefined) this.setHeader(name, value);
      }
    }
    this.headersSent = true;
    return this;
  }

  override _write(
    chunk: unknown,
    encoding: BufferEncoding,
    callback: (error?: Error | null) => void
  ): void {
    if (this.writableFinished) {
      callback(new Error("response is already finished"));
      return;
    }
    this.headersSent = true;
    this.ensureResponse(true);
    const data =
      typeof chunk === "string"
        ? Buffer.from(chunk, encoding)
        : chunk instanceof Uint8Array
          ? chunk
          : Buffer.from(String(chunk));
    this.writer.write(data).then(
      () => callback(),
      (error) => callback(toError(error))
    );
  }

  override _final(callback: (error?: Error | null) => void): void {
    if (!this.responseResolved) {
      this.ensureResponse(false);
      callback();
      return;
    }
    this.writer.close().then(
      () => callback(),
      (error) => callback(toError(error))
    );
  }

  override _destroy(
    error: Error | null,
    callback: (error?: Error | null) => void
  ): void {
    if (!this.responseResolved) this.ensureResponse(false);
    this.writer.abort(error ?? undefined).then(
      () => callback(error),
      () => callback(error)
    );
  }

  private ensureResponse(withBody: boolean): void {
    if (this.responseResolved) return;
    this.responseResolved = true;
    this.resolveResponse(
      new Response(withBody ? this.stream.readable : undefined, {
        status: this.statusCode,
        statusText: this.statusMessage,
        headers: this.headers,
      })
    );
  }
}

function toError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

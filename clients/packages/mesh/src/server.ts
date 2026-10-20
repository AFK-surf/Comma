// The serving side of the mesh: accepts connections, admits each by its client's credential, and answers each request
// stream with the handler's reply. What a credential is and what a principal may do are the caller's (`verify`,
// `handle`); the mesh only carries them.
import type { BiStream, MeshConnection, MeshEndpoint } from "./link.ts";
import {
  CloseCode,
  FrameReader,
  MeshError,
  StreamCode,
  controlFrame,
  encodeFrame,
  requestFrame,
  sendBody,
  type Body,
  type Headers,
} from "./wire.ts";

/** Who a credential names, and until when it holds (ms since the epoch; none: until the connection closes). */
export interface Admission<P> {
  principal: P;
  expiresAtMs?: number | undefined;
}

export interface ServedRequest<P> {
  /** The client's endpoint id (authenticated by QUIC). */
  peer: string;
  principal: P;
  method: string;
  path: string;
  headers: Headers;
  body: AsyncIterable<Uint8Array>;
  /** Aborted when the client gives the request up or the connection goes. */
  signal: AbortSignal;
}

export interface MeshReply {
  status: number;
  headers?: Headers;
  body?: Body;
}

export interface MeshServerOptions<P> {
  endpoint: MeshEndpoint;
  /**
   * The principal a credential from `peer` names, or a rejection (a `MeshError` gives the client its code and message;
   * anything else is `unauthorized`).
   */
  verify(credential: string, peer: string): Promise<Admission<P>>;
  handle(request: ServedRequest<P>): Promise<MeshReply>;
  /** The time, to check a credential's expiry by (default: the system clock). */
  now?: () => number;
  /** Told of a handler's failure (the client is told only `internal`). */
  onError?: (error: unknown) => void;
}

export interface MeshServer {
  /** Stops accepting (the next connection is turned away); connections already open run on until they close. */
  close(): void;
  /** Resolves once the accept loop ended: after `close` and the next connection, or when the endpoint closes. */
  readonly done: Promise<void>;
}

/** Serves requests on `endpoint` until it closes or `close` is called. */
export function serveMesh<P>(options: MeshServerOptions<P>): MeshServer {
  let stopped = false;
  const done = (async () => {
    for (;;) {
      const connection = await options.endpoint.accept();
      if (connection === null) return;
      if (stopped) {
        connection.close(CloseCode.done, "closing");
        return;
      }
      void serveMeshConnection(connection, options);
    }
  })();
  return {
    close: () => {
      stopped = true;
    },
    done,
  };
}

/**
 * Serves one connection that the caller accepted itself (an endpoint that also speaks other protocols): its
 * credential first, then each request stream, until it closes. `options.endpoint` is not used.
 */
export async function serveMeshConnection<P>(
  connection: MeshConnection,
  options: Omit<MeshServerOptions<P>, "endpoint">
): Promise<void> {
  const now = options.now ?? Date.now;
  const peer = connection.remoteId;
  const control = await connection.acceptBi().catch(() => null);
  if (!control) return;
  const reader = new FrameReader((max) => control.recv.read(max));
  const say = (frame: object) => control.send.write(encodeFrame(frame));

  const admit = async (credential: string): Promise<Admission<P> | null> => {
    try {
      return await options.verify(credential, peer);
    } catch (error) {
      const refused =
        error instanceof MeshError
          ? { type: "refused", code: error.code, message: error.message }
          : {
              type: "refused",
              code: "unauthorized",
              message: "The credential was refused.",
            };
      // The client closes once it has read this; the connection serves nothing more meanwhile.
      await say(refused)
        .then(() => control.send.finish())
        .catch(() => undefined);
      return null;
    }
  };

  let admission: Admission<P> | null;
  try {
    const hello = await reader.frame();
    if (hello === null) return;
    const frame = controlFrame(hello);
    if (frame.type !== "hello")
      throw new MeshError("protocol", "The first frame is not hello.");
    admission = await admit(frame.credential);
    if (!admission) return;
    await say({ type: "welcome" });
  } catch {
    connection.close(CloseCode.protocol, "protocol");
    return;
  }

  // Renewals, read as the client sends them; a refused one ends what the connection may do.
  void (async () => {
    try {
      for (;;) {
        const next = await reader.frame();
        if (next === null) return;
        const frame = controlFrame(next);
        if (frame.type !== "credential")
          throw new MeshError("protocol", "Only credentials follow hello.");
        const renewed = await admit(frame.credential);
        admission = renewed;
        if (!renewed) return;
        await say({ type: "renewed" });
      }
    } catch {
      connection.close(CloseCode.protocol, "protocol");
    }
  })();

  // Every request under way is given up when the connection goes.
  const gone = new AbortController();
  void connection.closed().then(() => gone.abort());
  for (;;) {
    const stream = await connection.acceptBi().catch(() => null);
    if (!stream) return;
    void serveRequest(stream, peer, () => admission, now, gone.signal, options);
  }
}

async function serveRequest<P>(
  stream: BiStream,
  peer: string,
  admission: () => Admission<P> | null,
  now: () => number,
  connectionGone: AbortSignal,
  options: Omit<MeshServerOptions<P>, "endpoint">
): Promise<void> {
  const { send, recv } = stream;
  const cancel = new AbortController();
  const signal = AbortSignal.any([cancel.signal, connectionGone]);
  const fail = async (code: string, message: string) => {
    await send.write(encodeFrame({ type: "error", code, message }));
    await send.finish();
  };
  try {
    const reader = new FrameReader((max) => recv.read(max));
    const head = await reader.frame();
    if (head === null) return;
    const request = requestFrame(head);
    const admitted = admission();
    if (!admitted) {
      recv.stop(StreamCode.cancelled);
      await fail("unauthorized", "The credential was refused.");
      return;
    }
    if (admitted.expiresAtMs !== undefined && admitted.expiresAtMs <= now()) {
      recv.stop(StreamCode.cancelled);
      await fail("credential_expired", "The credential expired.");
      return;
    }
    const body = (async function* () {
      try {
        yield* reader.body();
      } catch (error) {
        cancel.abort();
        throw error;
      }
    })();
    let reply: MeshReply;
    try {
      reply = await options.handle({
        peer,
        principal: admitted.principal,
        method: request.method,
        path: request.path,
        headers: request.headers,
        body,
        signal,
      });
    } catch (error) {
      options.onError?.(error);
      recv.stop(StreamCode.cancelled);
      await fail("internal", "The request failed.");
      return;
    }
    await send.write(
      encodeFrame({
        type: "response",
        status: reply.status,
        headers: reply.headers ?? [],
      })
    );
    await sendBody(send, reply.body);
  } catch (error) {
    if (
      error instanceof MeshError &&
      (error.code === "protocol" || error.code === "frame_too_large")
    ) {
      send.reset(StreamCode.protocol);
      recv.stop(StreamCode.protocol);
      return;
    }
    // The client gave the request up, or the connection went.
    cancel.abort();
    send.reset(StreamCode.cancelled);
  }
}

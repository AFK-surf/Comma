// The client side of the mesh: requests to peers, one connection per peer, opened when the first request needs it
// and again after it went. The credential comes from the caller each time one is needed (a hello, a renewal); the mesh
// keeps none.
import type {
  CloseInfo,
  MeshConnection,
  MeshEndpoint,
  MeshVia,
  PeerAddr,
  ViaChange,
} from "./link.ts";
import {
  CloseCode,
  FrameReader,
  MESH_ALPN,
  MeshError,
  StreamCode,
  controlFrame,
  encodeFrame,
  replyFrame,
  sendBody,
  type Body,
  type ControlFrame,
  type Headers,
} from "./wire.ts";

export interface MeshRequest {
  method: string;
  /** From `/`, with its query. */
  path: string;
  headers?: Headers;
  body?: Body;
}

export interface MeshResponse {
  status: number;
  headers: Headers;
  /** The body as it arrives. Read it to the end, or `cancel` it. */
  body: AsyncIterable<Uint8Array>;
  /** Gives the rest of the body up. */
  cancel(): void;
}

export interface MeshClientOptions {
  endpoint: MeshEndpoint;
  /** A fresh credential for `peer`: asked for each connection's hello, and again when the peer says it expired. */
  credential(peer: PeerAddr): Promise<string>;
  alpn?: string;
}

type Link = {
  connection: MeshConnection;
  /** Sends a control frame and waits for the server's answer (one at a time, in order). */
  control(frame: ControlFrame): Promise<ControlFrame>;
};

export class MeshClient {
  readonly #options: MeshClientOptions;
  readonly #links = new Map<string, Promise<Link>>();
  /** The link each pending entry above became, once it did. */
  readonly #opened = new Map<string, Link>();
  #closed = false;

  constructor(options: MeshClientOptions) {
    this.#options = options;
  }

  /**
   * One request to `peer`. A peer that says the credential expired gets a fresh one and the request again, once, when
   * its body can be sent again (bytes or none). Aborting `signal` gives the request and its response up.
   */
  async request(
    peer: PeerAddr,
    request: MeshRequest,
    signal?: AbortSignal
  ): Promise<MeshResponse> {
    const first = await this.#attempt(peer, request, signal);
    if (first.kind === "response") return first.response;
    const replayable =
      request.body === undefined ||
      request.body === null ||
      request.body instanceof Uint8Array;
    if (first.code !== "credential_expired" || !replayable)
      throw new MeshError(first.code, first.message);
    await this.#renew(peer);
    const second = await this.#attempt(peer, request, signal);
    if (second.kind === "response") return second.response;
    throw new MeshError(second.code, second.message);
  }

  /**
   * Opens the connection to `peer` without a request (its hello answered), or finds the one open: what it resolves
   * with settles when that connection closes.
   */
  async connect(peer: PeerAddr): Promise<{ closed: Promise<CloseInfo> }> {
    const link = await this.#link(peer);
    return { closed: link.connection.closed() };
  }

  /**
   * How the open connection to `peerId` runs once that is not `last` (`MeshConnection.nextVia`): closed when none is
   * open; null when the connection does not say.
   */
  async nextVia(peerId: string, last: MeshVia | null): Promise<ViaChange | null> {
    const link = this.#opened.get(peerId);
    if (!link) return { via: null, closed: true };
    return link.connection.nextVia ? link.connection.nextVia(last) : null;
  }

  /** Closes the connection to `peer`; the next request opens another. */
  disconnect(peerId: string): void {
    const link = this.#links.get(peerId);
    this.#links.delete(peerId);
    this.#opened.delete(peerId);
    void link
      ?.then((l) => l.connection.close(CloseCode.done, "disconnect"))
      .catch(() => undefined);
  }

  close(): void {
    this.#closed = true;
    for (const id of this.#links.keys()) this.disconnect(id);
  }

  async #attempt(
    peer: PeerAddr,
    request: MeshRequest,
    signal: AbortSignal | undefined
  ): Promise<
    | { kind: "response"; response: MeshResponse }
    | { kind: "error"; code: string; message: string }
  > {
    signal?.throwIfAborted();
    let link = await this.#link(peer);
    let stream;
    try {
      stream = await link.connection.openBi();
    } catch {
      // The connection went before this request began (nothing of it was sent): once more on a new one.
      this.#drop(peer.id, link);
      link = await this.#link(peer);
      try {
        stream = await link.connection.openBi();
      } catch (error) {
        this.#drop(peer.id, link);
        throw disconnected(error);
      }
    }
    const { send, recv } = stream;
    const abort = () => {
      send.reset(StreamCode.cancelled);
      recv.stop(StreamCode.cancelled);
    };
    signal?.addEventListener("abort", abort, { once: true });
    const done = () => signal?.removeEventListener("abort", abort);
    try {
      await send.write(
        encodeFrame({
          type: "request",
          method: request.method,
          path: request.path,
          headers: request.headers ?? [],
        })
      );
      // The body goes while the answer is read: a server may answer before it has all of it.
      const sent = sendBody(send, request.body).catch((error: unknown) => {
        recv.stop(StreamCode.cancelled);
        throw error;
      });
      sent.catch(() => undefined);
      const reader = new FrameReader((max) => recv.read(max));
      const head = await reader.frame();
      if (head === null) throw new MeshError("protocol", "The peer answered nothing.");
      const reply = replyFrame(head);
      if (reply.type === "error") {
        done();
        return { kind: "error", code: reply.code, message: reply.message };
      }
      const body = (async function* () {
        try {
          yield* reader.body();
        } catch (error) {
          throw signal?.aborted
            ? new MeshError("cancelled", "The request was given up.")
            : disconnected(error);
        } finally {
          done();
        }
      })();
      return {
        kind: "response",
        response: {
          status: reply.status,
          headers: reply.headers,
          body,
          cancel: () => {
            abort();
            done();
          },
        },
      };
    } catch (error) {
      done();
      abort();
      if (signal?.aborted)
        throw new MeshError("cancelled", "The request was given up.");
      if (error instanceof MeshError) throw error;
      throw disconnected(error);
    }
  }

  async #renew(peer: PeerAddr): Promise<void> {
    const link = await this.#link(peer);
    const credential = await this.#options.credential(peer);
    const answer = await link.control({ type: "credential", credential });
    if (answer.type !== "renewed") {
      this.#drop(peer.id, link);
      throw refusedError(answer);
    }
  }

  #link(peer: PeerAddr): Promise<Link> {
    if (this.#closed)
      return Promise.reject(new MeshError("closed", "The mesh client is closed."));
    const existing = this.#links.get(peer.id);
    if (existing) return existing;
    const opening = this.#open(peer);
    this.#links.set(peer.id, opening);
    opening.then(
      (link) => {
        if (this.#links.get(peer.id) === opening) this.#opened.set(peer.id, link);
        void link.connection.closed().then(() => this.#forget(peer.id, link));
      },
      () => {
        if (this.#links.get(peer.id) === opening) this.#links.delete(peer.id);
      }
    );
    return opening;
  }

  async #open(peer: PeerAddr): Promise<Link> {
    let connection: MeshConnection;
    try {
      connection = await this.#options.endpoint.connect(
        peer,
        this.#options.alpn ?? MESH_ALPN
      );
    } catch (error) {
      throw new MeshError(
        "unreachable",
        `The peer cannot be reached: ${messageOf(error)}`
      );
    }
    if (connection.remoteId !== peer.id) {
      connection.close(CloseCode.protocol, "wrong peer");
      throw new MeshError("unreachable", "Another peer answered.");
    }
    try {
      const { send, recv } = await connection.openBi();
      const reader = new FrameReader((max) => recv.read(max));
      let queue: Promise<unknown> = Promise.resolve();
      const control = (frame: ControlFrame): Promise<ControlFrame> => {
        const next = queue.then(async () => {
          await send.write(encodeFrame(frame));
          const answer = await reader.frame();
          if (answer === null)
            throw new MeshError("disconnected", "The peer closed the control stream.");
          return controlFrame(answer);
        });
        queue = next.catch(() => undefined);
        return next;
      };
      const credential = await this.#options.credential(peer);
      const answer = await control({ type: "hello", version: 1, credential });
      if (answer.type !== "welcome") {
        connection.close(CloseCode.done, "refused");
        throw refusedError(answer);
      }
      return { connection, control };
    } catch (error) {
      connection.close(CloseCode.done, "hello failed");
      if (error instanceof MeshError) throw error;
      throw disconnected(error);
    }
  }

  #drop(peerId: string, link: Link): void {
    this.#forget(peerId, link);
    link.connection.close(CloseCode.done, "dropped");
  }

  /** The next request to `peerId` opens a new connection, if `link` is still the one it would use. */
  #forget(peerId: string, link: Link): void {
    if (this.#opened.get(peerId) !== link) return;
    this.#opened.delete(peerId);
    this.#links.delete(peerId);
  }
}

function refusedError(answer: ControlFrame): MeshError {
  return answer.type === "refused"
    ? new MeshError(answer.code, answer.message)
    : new MeshError("protocol", "The peer answered out of turn.");
}

const messageOf = (error: unknown) =>
  error instanceof Error ? error.message : String(error);

function disconnected(error: unknown): MeshError {
  return error instanceof MeshError
    ? error
    : new MeshError("disconnected", `The connection went: ${messageOf(error)}`);
}

// The client side of the mesh: requests to peers, one connection per peer, opened when the first request needs it
// and again after it went. The credential comes from the caller each time one is needed (a hello, a renewal); the mesh
// keeps none.
import type {
  BiStream,
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
  PING_PATH,
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
  /** Anything the peer sent on the connection, on any stream. */
  heard: Heard;
};

/** What a connection heard from its peer: each read that brought bytes, and who waits for the next. */
class Heard {
  #next: (() => void)[] = [];

  hear(): void {
    const next = this.#next;
    this.#next = [];
    for (const go of next) go();
  }

  /** Resolves once the peer sends anything more. */
  next(): Promise<void> {
    return new Promise((go) => this.#next.push(go));
  }

  /** `connection`, what its streams read heard. */
  of(connection: MeshConnection): MeshConnection {
    const { nextVia } = connection;
    return {
      remoteId: connection.remoteId,
      ...(nextVia
        ? { nextVia: (last: MeshVia | null) => nextVia.call(connection, last) }
        : {}),
      openBi: async () => this.counted(await connection.openBi()),
      acceptBi: async () => {
        const stream = await connection.acceptBi();
        return stream && this.counted(stream);
      },
      closed: () => connection.closed(),
      close: (code, reason) => connection.close(code, reason),
    };
  }

  /** `stream`, its reads heard. */
  counted(stream: BiStream): BiStream {
    const { send, recv } = stream;
    return {
      send,
      recv: {
        read: async (max) => {
          const got = await recv.read(max);
          if (got !== null && got.length > 0) this.hear();
          return got;
        },
        stop: (code) => recv.stop(code),
      },
    };
  }
}

/** What a connection is kept under: the peer, in what it is for. */
export const peerKey = (peer: PeerAddr) =>
  peer.scope ? `${peer.id}@${peer.scope}` : peer.id;

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

  /**
   * Opens a new connection to `peer` beside the open one, which carries nothing though it is still open, and puts it in
   * that one's place once its hello is answered: the old one is closed, and what was on it fails, to be asked again on
   * the new. For a peer whose process went and came back (QUIC finds that out only at its idle timeout). `wanted` is
   * asked once the new one opened: false (the old one spoke again meanwhile: the network only paused) closes the new one
   * and keeps the old. True when it was replaced; false when none was open, none opened, or it was not wanted.
   */
  async refresh(peer: PeerAddr, wanted: () => boolean = () => true): Promise<boolean> {
    const key = peerKey(peer);
    const old = this.#opened.get(key);
    if (!old || this.#closed) return false;
    let fresh: Link;
    try {
      fresh = await this.#open(peer);
    } catch {
      return false;
    }
    if (this.#opened.get(key) !== old || this.#closed || !wanted()) {
      fresh.connection.close(CloseCode.done, "not needed");
      return false;
    }
    this.#links.set(key, Promise.resolve(fresh));
    this.#opened.set(key, fresh);
    void fresh.connection.closed().then(() => this.#forget(key, fresh));
    old.connection.close(CloseCode.done, "replaced");
    return true;
  }

  /**
   * Asks the peer on the open connection whether it is still there: resolves once the question is written (a stream to
   * write it on may be a while coming), or once the peer sent anything meanwhile, with `answered`, which resolves once
   * the peer sent anything after it was asked and fails once the connection closes. A peer gone with the connection
   * still open sends nothing, and the caller gives it up after its own while. Fails when none is open.
   */
  async ping(peer: PeerAddr): Promise<{ answered: Promise<void> }> {
    const link = this.#opened.get(peerKey(peer));
    if (!link || this.#closed)
      throw new MeshError("disconnected", "No connection is open.");
    // Anything heard from now on answers it: the question's own answer, or what a busy connection carries before it
    // (a slow link full of a screen's frames is still there). A peer older than PING_PATH answers it as any unknown path.
    const heard = link.heard.next();
    const closed = link.connection.closed().then(() => {
      throw new MeshError("disconnected", "The connection closed.");
    });
    closed.catch(() => undefined);
    const written = (async () => {
      const { send, recv } = await link.connection.openBi();
      try {
        await send.write(
          encodeFrame({ type: "request", method: "GET", path: PING_PATH, headers: [] })
        );
        await send.finish();
      } catch (error) {
        recv.stop(StreamCode.cancelled);
        throw disconnected(error);
      }
      // Read to its end, as the stream lasts until it is (a binding that cannot stop a reading half): one left unread
      // counts against the streams the peer lets be open, and a ping each 2 s would use them up.
      void (async () => {
        while ((await recv.read(64 * 1024)) !== null);
      })().catch(() => undefined);
      void Promise.race([heard, closed])
        .finally(() => recv.stop(StreamCode.cancelled))
        .catch(() => undefined);
    })();
    written.catch(() => undefined);
    // Heard before the question could even be written (no stream to be had: the peer's are all open): that answers it.
    await Promise.race([written, heard]);
    const answered = Promise.race([heard, closed]);
    answered.catch(() => undefined);
    return { answered };
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
      this.#drop(peerKey(peer), link);
      link = await this.#link(peer);
      try {
        stream = await link.connection.openBi();
      } catch (error) {
        this.#drop(peerKey(peer), link);
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
      // The body goes while the answer is read: a server may answer before it has all of it, and may stop reading it
      // (it refused the request): the answer is read on. Only a body that failed itself gives the answer up.
      let bodyFailed = false;
      const given = request.body;
      const sending =
        given && !(given instanceof Uint8Array)
          ? (async function* () {
              try {
                yield* given;
              } catch (error) {
                bodyFailed = true;
                throw error;
              }
            })()
          : given;
      const sent = sendBody(send, sending).catch((error: unknown) => {
        if (bodyFailed) recv.stop(StreamCode.cancelled);
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
      this.#drop(peerKey(peer), link);
      throw refusedError(answer);
    }
  }

  #link(peer: PeerAddr): Promise<Link> {
    if (this.#closed)
      return Promise.reject(new MeshError("closed", "The mesh client is closed."));
    const key = peerKey(peer);
    const existing = this.#links.get(key);
    if (existing) return existing;
    const opening = this.#open(peer);
    this.#links.set(key, opening);
    opening.then(
      (link) => {
        if (this.#links.get(key) === opening) this.#opened.set(key, link);
        void link.connection.closed().then(() => this.#forget(key, link));
      },
      () => {
        if (this.#links.get(key) === opening) this.#links.delete(key);
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
    const heard = new Heard();
    connection = heard.of(connection);
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
      return { connection, control, heard };
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

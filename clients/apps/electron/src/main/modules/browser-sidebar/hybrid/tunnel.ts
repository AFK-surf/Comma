import { WebSocket, type RawData } from "ws";
import {
  CableHandshake,
  cableConnectUrl,
  cableMessageType,
  parsePostHandshake,
  type CableAdvert,
  type CableCrypter,
  type CableQrSession,
} from "./cable";

export class CableTransportError extends Error {
  constructor(
    message: string,
    /** The phone closed the tunnel; a phone does so when its user cancels. */
    readonly phoneClosed = false
  ) {
    super(message);
    this.name = "CableTransportError";
  }
}

export interface CableCtapReply {
  status: number;
  /** The CBOR body after the status byte. Empty when the status is an error. */
  body: Uint8Array;
}

export interface CableTransaction {
  session: CableQrSession;
  advert: CableAdvert;
  /** Builds the one CTAP command from the phone's getInfo: `cmd ‖ CBOR`. */
  command(getInfo: Map<number, unknown>): Uint8Array;
  signal: AbortSignal;
  /** Called once the handshake succeeded and the phone waits for the user. */
  onConnected?: (() => void) | undefined;
  /** Replaces `wss://<tunnel domain>` for tests; the path stays the same. */
  tunnelOrigin?: string | undefined;
  /** Chromium has no tunnel timer of its own; this bounds connect and handshake. */
  connectTimeoutMs?: number | undefined;
}

const fidoCableProtocol = "fido.cable";
const maxMessageBytes = 1 << 20;

/**
 * Runs one QR-initiated transaction: connect, handshake, read the phone's
 * getInfo, send one CTAP command, and return its reply. Phones accept a single
 * command per tunnel, so getInfo is never sent over the wire.
 */
export async function runCableTransaction({
  session,
  advert,
  command,
  signal,
  onConnected,
  tunnelOrigin,
  connectTimeoutMs = 30_000,
}: CableTransaction): Promise<CableCtapReply> {
  let url = cableConnectUrl(session, advert);
  if (tunnelOrigin) url = url.replace(`wss://${advert.domain}`, tunnelOrigin);
  const socket = new WebSocket(url, fidoCableProtocol, {
    followRedirects: false,
    handshakeTimeout: connectTimeoutMs,
    maxPayload: maxMessageBytes,
    origin: `wss://${advert.domain}`,
  });
  const messages = new MessageQueue(socket, signal);
  try {
    await new Promise<void>((resolve, reject) => {
      socket.once("open", () => resolve());
      socket.once("error", (error) => reject(new CableTransportError(error.message)));
      socket.once("unexpected-response", (_request, response) =>
        reject(
          new CableTransportError(`The tunnel answered HTTP ${response.statusCode}.`)
        )
      );
    });
    if (socket.protocol !== fidoCableProtocol) {
      throw new CableTransportError("The tunnel did not select the caBLE protocol.");
    }
    const handshake = new CableHandshake(session, advert);
    socket.send(handshake.message);
    const deadline = AbortSignal.timeout(connectTimeoutMs);
    let crypter: CableCrypter;
    try {
      crypter = handshake.finish(await messages.next(deadline));
    } catch (error) {
      throw asTransportError(error);
    }
    const { revision, getInfo } = parsePostHandshake(
      decryptOrFail(crypter, await messages.next(deadline))
    );
    onConnected?.();

    const frame = command(getInfo);
    socket.send(
      crypter.encrypt(
        revision === 1
          ? Buffer.concat([Buffer.from([cableMessageType.ctap]), frame])
          : frame
      )
    );
    for (;;) {
      const plaintext = decryptOrFail(crypter, await messages.next());
      let reply = plaintext;
      if (revision === 1) {
        const type = plaintext[0];
        // Phones send linking updates before the reply; they need no answer.
        if (type === cableMessageType.update) continue;
        if (type !== cableMessageType.ctap) {
          throw new CableTransportError("The phone sent an unexpected message.");
        }
        reply = plaintext.subarray(1);
      }
      if (reply.length === 0) {
        throw new CableTransportError("The phone sent an empty reply.");
      }
      if (revision === 1) {
        socket.send(crypter.encrypt(Buffer.from([cableMessageType.shutdown])));
      }
      return { status: reply[0]!, body: reply.subarray(1) };
    }
  } finally {
    messages.dispose();
    socket.close();
  }
}

function asTransportError(error: unknown) {
  return error instanceof CableTransportError || isAbortError(error)
    ? error
    : new CableTransportError(error instanceof Error ? error.message : String(error));
}

function isAbortError(error: unknown) {
  return (
    error instanceof DOMException || (error as Error | undefined)?.name === "AbortError"
  );
}

function decryptOrFail(crypter: CableCrypter, ciphertext: Buffer) {
  try {
    return crypter.decrypt(ciphertext);
  } catch (error) {
    throw asTransportError(error);
  }
}

/** Binary messages from the socket, read one at a time. */
class MessageQueue {
  readonly #queued: Buffer[] = [];
  readonly #waiters: Array<{
    resolve(message: Buffer): void;
    reject(error: unknown): void;
  }> = [];
  #failure: unknown;
  readonly #socket: WebSocket;
  readonly #onAbort: () => void;
  readonly #signal: AbortSignal;

  constructor(socket: WebSocket, signal: AbortSignal) {
    this.#socket = socket;
    this.#signal = signal;
    socket.on("message", (data: RawData, isBinary: boolean) => {
      if (!isBinary) {
        this.#fail(new CableTransportError("The tunnel sent a text message."));
        return;
      }
      const message = Array.isArray(data)
        ? Buffer.concat(data)
        : Buffer.from(data as ArrayBuffer);
      const waiter = this.#waiters.shift();
      if (waiter) waiter.resolve(message);
      else this.#queued.push(message);
    });
    socket.on("close", () =>
      this.#fail(new CableTransportError("The phone closed the connection.", true))
    );
    socket.on("error", (error) => this.#fail(new CableTransportError(error.message)));
    this.#onAbort = () => {
      this.#fail(signal.reason ?? new DOMException("Aborted", "AbortError"));
      socket.close();
    };
    if (signal.aborted) this.#onAbort();
    else signal.addEventListener("abort", this.#onAbort, { once: true });
  }

  next(deadline?: AbortSignal): Promise<Buffer> {
    const queued = this.#queued.shift();
    if (queued) return Promise.resolve(queued);
    if (this.#failure !== undefined) return Promise.reject(this.#failure);
    return new Promise((resolve, reject) => {
      const waiter = {
        resolve: (message: Buffer) => {
          deadline?.removeEventListener("abort", onDeadline);
          resolve(message);
        },
        reject: (error: unknown) => {
          deadline?.removeEventListener("abort", onDeadline);
          reject(error);
        },
      };
      const onDeadline = () => {
        const index = this.#waiters.indexOf(waiter);
        if (index !== -1) this.#waiters.splice(index, 1);
        reject(new CableTransportError("The phone did not answer in time."));
      };
      if (deadline?.aborted) {
        onDeadline();
        return;
      }
      deadline?.addEventListener("abort", onDeadline, { once: true });
      this.#waiters.push(waiter);
    });
  }

  #fail(error: unknown) {
    if (this.#failure !== undefined) return;
    this.#failure = error;
    for (const waiter of this.#waiters.splice(0)) waiter.reject(error);
  }

  dispose() {
    this.#signal.removeEventListener("abort", this.#onAbort);
    this.#socket.removeAllListeners("message");
  }
}

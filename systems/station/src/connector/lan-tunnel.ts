// lan_tcp_dial: one TCP connection from this gateway, relayed over the connector socket (ssh.open through a gateway
// device). The request answers once the connection is up; both directions then use `stream` frames under its id:
//   {"channel":"tcp","data":<base64>}  bytes, at most LAN_TUNNEL_MAX_FRAME each
//   {"channel":"tcp","eof":true}       either side closed (with "error" on failure)
//   {"channel":"tcp_ack","seq":<n>}    the receiver has written n bytes in total
// A sender keeps at most one window unacknowledged, so neither side buffers more than a window per tunnel. A tunnel
// ends with its socket, with a scope downgrade, or when either side sends eof.
import { Deferred, Effect, Exit } from "effect";
import type { Message } from "./message.ts";
import type { NetSocket } from "./net.ts";

export const LAN_TUNNEL_CHANNEL = "tcp";
export const LAN_TUNNEL_ACK_CHANNEL = "tcp_ack";
export const LAN_TUNNEL_MAX_FRAME = 32 * 1024;
export const LAN_TUNNEL_WINDOW = 512 * 1024;
export const LAN_TUNNEL_MAX_OPEN = 8;

/** What a tunnel needs from its connection generation. */
export type TunnelHost = {
  send(message: Message): Effect.Effect<void, Error>;
  remove(id: string, tunnel: LanTunnel): void;
  fork<A, E>(effect: Effect.Effect<A, E>): void;
};

export class LanTunnel {
  readonly id: string;
  private readonly host: TunnelHost;
  private conn: NetSocket | null = null;
  private incoming: Buffer[] = [];
  private queued = 0;
  private sent = 0;
  private acked = 0;
  private closed = false;
  private changed = Deferred.makeUnsafe<void>();
  private ready = Deferred.makeUnsafe<void>();

  constructor(id: string, host: TunnelHost) {
    this.id = id;
    this.host = host;
  }

  get isClosed() {
    return this.closed;
  }

  attach(conn: NetSocket): boolean {
    if (this.closed) return false;
    this.conn = conn;
    this.host.fork(this.readLoop());
    this.host.fork(this.writeLoop());
    return true;
  }

  /** Closes once; `notify` tells the server unless it closed the tunnel itself. */
  finish(reason: string, notify: boolean): Effect.Effect<void> {
    return Effect.suspend(() => {
      if (this.closed) return Effect.void;
      this.closed = true;
      Deferred.doneUnsafe(this.changed, Exit.void);
      Deferred.doneUnsafe(this.ready, Exit.void);
      const conn = this.conn;
      this.host.remove(this.id, this);
      const closing = conn ? conn.close : Effect.void;
      const notice = notify ? this.host.send({ id: this.id, type: "stream", error: reason, stream: { channel: LAN_TUNNEL_CHANNEL, eof: true } }).pipe(Effect.ignore) : Effect.void;
      return closing.pipe(Effect.andThen(notice));
    });
  }

  private readLoop(): Effect.Effect<void> {
    const self = this;
    return Effect.gen(function* () {
      while (true) {
        const room = yield* self.waitWindow();
        if (room <= 0) return;
        const chunk = yield* self.conn!.read;
        if (chunk === null) {
          yield* self.finish("", true);
          return;
        }
        // A read never takes more than the window allows: what is beyond waits in the socket.
        let offset = 0;
        while (offset < chunk.length) {
          const space = yield* self.waitWindow();
          if (space <= 0) return;
          const piece = chunk.subarray(offset, offset + Math.min(space, LAN_TUNNEL_MAX_FRAME, chunk.length - offset));
          offset += piece.length;
          self.sent += piece.length;
          const sent = yield* Effect.exit(self.host.send({ id: self.id, type: "stream", stream: { channel: LAN_TUNNEL_CHANNEL, data: piece.toString("base64") } }));
          if (Exit.isFailure(sent)) {
            yield* self.finish("connector socket closed", false);
            return;
          }
        }
      }
    });
  }

  /** Waits while a full window is unacknowledged; 0 once closed. */
  private waitWindow(): Effect.Effect<number> {
    const self = this;
    return Effect.gen(function* () {
      while (true) {
        if (self.closed) return 0;
        const room = LAN_TUNNEL_WINDOW - (self.sent - self.acked);
        if (room > 0) return room;
        yield* Deferred.await(self.changed);
      }
    });
  }

  private writeLoop(): Effect.Effect<void> {
    const self = this;
    return Effect.gen(function* () {
      let written = 0;
      while (true) {
        const data = yield* self.next();
        if (!data) return;
        const wrote = yield* Effect.exit(self.conn!.write(data));
        if (Exit.isFailure(wrote)) {
          yield* self.finish("tunnel write failed", true);
          return;
        }
        written += data.length;
        const acked = yield* Effect.exit(self.host.send({ id: self.id, type: "stream", stream: { channel: LAN_TUNNEL_ACK_CHANNEL, seq: written } }));
        if (Exit.isFailure(acked)) {
          yield* self.finish("connector socket closed", false);
          return;
        }
      }
    });
  }

  private next(): Effect.Effect<Buffer | null> {
    const self = this;
    return Effect.gen(function* () {
      while (true) {
        if (self.closed) return null;
        const data = self.incoming.shift();
        if (data) {
          self.queued -= data.length;
          return data;
        }
        yield* Deferred.await(self.ready);
        if (!self.closed) self.ready = Deferred.makeUnsafe<void>();
      }
    });
  }

  /** One frame from the server, handled without blocking the socket read loop. */
  receive(msg: Message) {
    const stream = msg.stream!;
    if (stream.channel === LAN_TUNNEL_ACK_CHANNEL) {
      const seq = stream.seq ?? 0;
      if (seq > this.acked && seq <= this.sent) {
        this.acked = seq;
        if (!this.closed) {
          const previous = this.changed;
          this.changed = Deferred.makeUnsafe<void>();
          Deferred.doneUnsafe(previous, Exit.void);
        }
      }
      return;
    }
    if (stream.eof || msg.error) {
      this.host.fork(this.finish("", false));
      return;
    }
    if (stream.data) {
      const data = Buffer.from(stream.data, "base64");
      if (data.length > LAN_TUNNEL_MAX_FRAME || data.toString("base64").replace(/=+$/, "") !== stream.data.replace(/=+$/, "")) {
        this.host.fork(this.finish("invalid tunnel frame", true));
        return;
      }
      if (this.queued + data.length > LAN_TUNNEL_WINDOW) {
        this.host.fork(this.finish("tunnel window exceeded", true));
        return;
      }
      if (this.closed) return;
      this.queued += data.length;
      this.incoming.push(data);
      Deferred.doneUnsafe(this.ready, Exit.void);
    }
  }

  /** Pretends the writer holds `bytes` queued (the overflow test). */
  fillQueueForTest(bytes: number) {
    this.queued = bytes;
  }
}

export const isTunnelFrame = (msg: Message) => msg.stream !== undefined && (msg.stream.channel === LAN_TUNNEL_CHANNEL || msg.stream.channel === LAN_TUNNEL_ACK_CHANNEL);

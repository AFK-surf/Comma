import { randomUUID } from "node:crypto";
import { z } from "zod";
import { nearbyInviteToken } from "@comma/native-bridge";
import { realMainClock, type MainClock } from "../../clock";

/** The mDNS service type Comma's receivers advertise on the local network (`_comma-nearby._tcp`). */
export const lanNearbyServiceType = "comma-nearby";

/** One Comma receiver a browse found on the local network. */
export interface LanService {
  /** The receiver's own id, from its TXT record: it tells this Mac's receiver from others. */
  id: string;
  /** The name it advertises, the same as its AirDrop name. */
  name: string;
  /** Its AirDrop receiver's id, as an AirDrop scan reports that receiver; absent without one. */
  airDrop?: string | undefined;
  /** Addresses to reach it at, IPv4 first. */
  addresses: string[];
  port: number;
}

/** Node's HTTP and mDNS, behind what the service needs of them; tests give their own. */
export interface LanNearbyPlatform {
  /**
   * Listens on every interface on a free port and answers each POST of an
   * invite with the status `answer` resolves to.
   */
  listen(
    answer: (body: unknown, signal: AbortSignal) => Promise<number>
  ): Promise<{ port: number; close(): Promise<void> }>;
  advertise(service: {
    airDrop: string | undefined;
    id: string;
    name: string;
    port: number;
  }): { stop(): void };
  browse(found: (service: LanService) => void): { stop(): void };
  /**
   * POSTs `body` to the service; resolves with the HTTP status. Rejects with
   * `LanUnreachableError` when no address of the service took a connection
   * (nothing was sent), with another error when the exchange failed after one did.
   */
  post(service: LanService, body: unknown, signal: AbortSignal): Promise<number>;
}

/** No address of a receiver took a connection, so the invite never left this computer. */
export class LanUnreachableError extends Error {
  /** Each address tried, in order, with why it failed (an errno code, `timeout` or `aborted`). */
  readonly tried: readonly { address: string; code: string }[];

  constructor(tried: readonly { address: string; code: string }[]) {
    super(
      `No address connected: ${
        tried.map(({ address, code }) => `${address} ${code}`).join(", ") ||
        "none to try"
      }`
    );
    this.name = "LanUnreachableError";
    this.tried = tried;
  }
}

/**
 * How an invite sent over the local network ended: `accepted` by the person
 * there, `declined` (an answer other than yes, or no answer in time), or
 * `unreachable`: their computer could not be reached, so they never saw it.
 */
export type LanSendResult = "accepted" | "declined" | "unreachable";

const inviteBodySchema = z
  .object({
    version: z.literal(1),
    url: z.string().max(2_048),
    senderName: z.string().max(160).optional(),
  })
  .strict();

/** An invite someone on the local network sent this Mac or PC. */
export interface LanInvite {
  invite: string;
  requestId: string;
  senderName?: string | undefined;
}

/** How long a sender waits for the person here to answer, as an AirDrop offer does. */
const ANSWER_MS = 25_000;
const BROWSE_MS = 5_000;

/**
 * Nearby connect over the local network: the counterpart of the AirDrop
 * receiver and sender for people on the same Wi-Fi, on any desktop. The
 * receiver advertises `_comma-nearby._tcp` under its AirDrop name and takes one
 * thing over HTTP: an invite link, held until the person answers the connect
 * card. A sender browses for a few seconds and posts the link; the response is
 * the answer. Nothing but the link crosses: the server says whose invite it is.
 */
export class LanNearby {
  readonly #platform: LanNearbyPlatform;
  readonly #clock: MainClock;
  readonly #onInvite: (invite: LanInvite, signal: AbortSignal) => Promise<boolean>;
  readonly #log: { warn(message: string): void } | undefined;
  /** This receiver's id, so a browse leaves it out. */
  readonly id = randomUUID();
  #running:
    | {
        airDrop: string | undefined;
        name: string;
        close(): Promise<void>;
        advertised: { stop(): void };
      }
    | undefined;
  #starting: Promise<void> = Promise.resolve();

  constructor(options: {
    clock?: MainClock;
    log?: { warn(message: string): void } | undefined;
    onInvite: (invite: LanInvite, signal: AbortSignal) => Promise<boolean>;
    platform: LanNearbyPlatform;
  }) {
    this.#log = options.log;
    this.#platform = options.platform;
    this.#clock = options.clock ?? realMainClock;
    this.#onInvite = options.onInvite;
  }

  /**
   * Brings the receiver to what `wanted` says once `name` is read: on under that
   * name and this computer's AirDrop receiver id (`airDrop`, so a scan that finds
   * both can tell it is one receiver), restarted if either changed, or off.
   * Starts and stops run in order, and `wanted` is asked after the name arrives,
   * so a sign-out or a hidden-nearby setting that came meanwhile keeps it off.
   */
  start(
    name: () => Promise<string>,
    wanted: () => boolean,
    airDrop: () => string | undefined = () => undefined
  ) {
    // A failed start (a name that could not be read) leaves the next one to run.
    this.#starting = this.#starting
      .catch(() => undefined)
      .then(async () => {
        const current = await name();
        if (!wanted()) {
          await this.#stop();
          return;
        }
        const airDropId = airDrop();
        if (this.#running?.name === current && this.#running.airDrop === airDropId)
          return;
        await this.#stop();
        const server = await this.#platform.listen((body, signal) =>
          this.#answer(body, signal)
        );
        this.#running = {
          airDrop: airDropId,
          name: current,
          close: server.close,
          advertised: this.#platform.advertise({
            airDrop: airDropId,
            id: this.id,
            name: current,
            port: server.port,
          }),
        };
      });
    return this.#starting;
  }

  stop() {
    this.#starting = this.#starting.catch(() => undefined).then(() => this.#stop());
    return this.#starting;
  }

  /** Browses for a few seconds; `found` hears each other receiver once. */
  find(found: (service: LanService) => void): Promise<void> {
    const seen = new Set<string>([this.id]);
    const browser = this.#platform.browse((service) => {
      if (seen.has(service.id) || !service.addresses.length) return;
      seen.add(service.id);
      found(service);
    });
    return new Promise((resolve) =>
      this.#clock.setTimer(BROWSE_MS, () => {
        browser.stop();
        resolve();
      })
    );
  }

  /**
   * Sends an invite link and tells how it ended (`LanSendResult`). Rejects when
   * the exchange failed after their computer took the connection (other than
   * by running out of time): the invite may have reached them, so it is
   * neither unreachable nor sent again.
   */
  async send(
    service: LanService,
    url: string,
    senderName: string
  ): Promise<LanSendResult> {
    const controller = new AbortController();
    // A little past the receiver's own wait, so its answer comes first.
    const cancel = this.#clock.setTimer(ANSWER_MS + 5_000, () => controller.abort());
    try {
      const status = await this.#platform.post(
        service,
        { version: 1, url, senderName },
        controller.signal
      );
      return status === 200 ? "accepted" : "declined";
    } catch (error) {
      // Their computer took the invite and gave no answer in time.
      if (!(error instanceof LanUnreachableError) && controller.signal.aborted)
        return "declined";
      if (!(error instanceof LanUnreachableError)) throw error;
      // Addresses and errno codes only: never the invite link.
      this.#log?.warn(
        `Nearby invite could not reach the receiver on port ${service.port}: ${error.message}`
      );
      return "unreachable";
    } finally {
      cancel();
    }
  }

  async #answer(body: unknown, signal: AbortSignal): Promise<number> {
    const parsed = inviteBodySchema.safeParse(body);
    const invite = parsed.success ? nearbyInviteToken(parsed.data.url) : null;
    if (!parsed.success || !invite) return 400;
    const controller = new AbortController();
    const abort = () => controller.abort();
    signal.addEventListener("abort", abort, { once: true });
    const cancel = this.#clock.setTimer(ANSWER_MS, abort);
    try {
      const accepted = await this.#onInvite(
        {
          invite,
          requestId: randomUUID(),
          ...(parsed.data.senderName ? { senderName: parsed.data.senderName } : {}),
        },
        controller.signal
      );
      return accepted ? 200 : 403;
    } finally {
      cancel();
      signal.removeEventListener("abort", abort);
    }
  }

  async #stop() {
    const running = this.#running;
    this.#running = undefined;
    if (!running) return;
    running.advertised.stop();
    await running.close();
  }
}

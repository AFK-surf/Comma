import { randomUUID } from "node:crypto";
import { rm } from "node:fs/promises";
import {
  emptyNearbyState,
  nearbyInviteToken,
  type NearbyState,
} from "@comma/native-bridge";
import { airDropReceiverModel, type AirDropIntake, type AirDropOffer } from ".";
import type { LanNearby, LanService } from "./lan-nearby";
import type { AirDropOperation, AirDropSender } from "./sender";

export interface NearbyProvider {
  state(input?: void): NearbyState;
  find(input?: void): NearbyState;
  ask(input: { inviteUrl: string; peerId: string }): NearbyState;
  answer(input: { accept: boolean; requestId: string }): NearbyState;
}

type Sender = Pick<AirDropSender, "find" | "idle" | "scanned" | "sendLink" | "status">;
type Peer = NearbyState["peers"][number];
/** A receiver on the local network is `lan:<its id>` in the list. */
const lanPeerId = (service: LanService) => `lan:${service.id}`;

interface HeldOffer {
  value: NearbyState["offers"][number];
  decide: (accept: boolean) => void;
}

/**
 * Settings › Task requests › Add someone nearby (see `nearbyStateSchema`), over
 * AirDrop on a Mac and over the local network (`LanNearby`) on any desktop.
 * Main scans both for Comma receivers and lists them together, one row a
 * person, AirDrop first; it sends a picked one an invite link the way it was
 * found. On the other computer it holds an invite until the person answers the
 * connect card, whichever way it came. One AirDrop scan or send runs at a time,
 * as the sender allows; AirDrop asks wait their turn.
 */
export class NearbyService implements NearbyProvider {
  readonly #sender: Sender;
  readonly #publish: (state: NearbyState) => void;
  readonly #senderName: () => Promise<string>;
  readonly #log: { warn(message: string): void } | undefined;
  readonly #offers = new Map<string, HeldOffer>();
  readonly #lan: Pick<LanNearby, "find" | "send"> | undefined;
  readonly #surfaceId: () => string | undefined;
  #airDropPeers: Peer[] = [];
  readonly #lanPeers = new Map<string, LanService>();
  /** The scans running: AirDrop's and the local network's. */
  readonly #scanning = new Set<"airdrop" | "lan">();
  #state: NearbyState = { ...emptyNearbyState };
  /** The scan or send this service started, to tell its changes from other callers'. */
  #operationId: string | undefined;
  #queue: Promise<unknown> = Promise.resolve();
  /** Moves on each session change: queued scans and sends of the last session never start. */
  #generation = 0;

  constructor(options: {
    /** Absent: no local network receiver here (`LanNearby`). */
    lan?: Pick<LanNearby, "find" | "send"> | undefined;
    log?: { warn(message: string): void } | undefined;
    publish: (state: NearbyState) => void;
    sender: Sender;
    /** The name the other Mac's AirDrop offer shows: this Mac's AirDrop name. */
    senderName: () => Promise<string>;
    /** The window that shows a local network invite's card. */
    surfaceId?: () => string | undefined;
  }) {
    this.#lan = options.lan;
    this.#surfaceId = options.surfaceId ?? (() => undefined);
    this.#sender = options.sender;
    this.#publish = options.publish;
    this.#senderName = options.senderName;
    this.#log = options.log;
  }

  state(): NearbyState {
    return {
      ...structuredClone(this.#state),
      available: this.#sender.status().available || this.#lan !== undefined,
      offers: [...this.#offers.values()].map((offer) => ({ ...offer.value })),
    };
  }

  /** Starts a scan unless one runs; found receivers appear as they answer. */
  find() {
    if (this.#scanning.size) return this.state();
    this.#airDropPeers = [];
    this.#lanPeers.clear();
    if (this.#sender.status().available) {
      this.#scanning.add("airdrop");
      void this.#serialize(() => this.#scan()).catch(() => undefined);
    }
    const lan = this.#lan;
    if (lan) {
      this.#scanning.add("lan");
      const generation = this.#generation;
      void lan
        .find((service) => {
          if (generation !== this.#generation) return;
          this.#lanPeers.set(lanPeerId(service), service);
          this.#peersChanged();
        })
        .then(() => {
          if (generation === this.#generation) this.#scanEnded("lan");
        });
    }
    this.#peersChanged();
    return this.state();
  }

  ask({ inviteUrl, peerId }: { inviteUrl: string; peerId: string }) {
    if (!nearbyInviteToken(inviteUrl)) throw new Error("Expected a Comma invite link.");
    if (!this.#state.peers.some((peer) => peer.id === peerId))
      throw new Error("Pick someone the last scan found.");
    this.#setAsk(peerId, "asking");
    const generation = this.#generation;
    const service = this.#lanPeers.get(peerId);
    if (service && this.#lan) {
      const lan = this.#lan;
      const current = this.#current(generation);
      void (async () => {
        const senderName = await this.#senderName();
        current();
        const accepted = await lan.send(service, inviteUrl, senderName);
        current();
        this.#setAsk(peerId, accepted ? "accepted" : "unanswered");
      })().catch((error: unknown) => {
        if (generation !== this.#generation) return;
        this.#log?.warn(
          `Nearby invite failed: ${error instanceof Error ? error.message : String(error)}`
        );
        this.#setAsk(peerId, "unanswered");
      });
      return this.state();
    }
    void this.#serialize(async (current) => {
      // A scan older than the sender keeps, or one still running, is scanned again first.
      if (!this.#sender.scanned(peerId)) await this.#scan();
      const senderName = await this.#senderName();
      current();
      const requestId = randomUUID();
      this.#operationId = requestId;
      this.#sender.sendLink({ peerId, requestId, senderName, url: inviteUrl });
      await this.#sender.idle();
    }).catch((error: unknown) => {
      // The session that asked has ended: its asks are gone with it.
      if (generation !== this.#generation) return;
      this.#log?.warn(
        `Nearby invite failed: ${error instanceof Error ? error.message : String(error)}`
      );
      this.#setAsk(peerId, "unanswered");
    });
    return this.state();
  }

  answer({ accept, requestId }: { accept: boolean; requestId: string }) {
    this.#offers.get(requestId)?.decide(accept);
    return this.state();
  }

  /**
   * An AirDrop offer of a single Comma invite link, or undefined for any other
   * offer. The returned promise settles with the person's answer: an intake
   * that drops the saved link once accepted, or undefined.
   */
  offer(
    offer: AirDropOffer,
    signal: AbortSignal,
    surfaceId: string | undefined
  ): Promise<AirDropIntake | undefined> | undefined {
    const [link] = offer.links;
    const invite =
      link && offer.files.length === 0 && offer.links.length === 1
        ? nearbyInviteToken(link)
        : null;
    if (!invite) return undefined;
    return this.#hold(
      { invite, requestId: offer.requestId, senderName: offer.senderName, surfaceId },
      signal
    ).then((accept) =>
      accept
        ? {
            // The receiver saved the link as a file; the core already accepted it.
            complete: async (paths) => {
              await Promise.all(paths.map((path) => rm(path, { force: true })));
            },
            cancel: () => undefined,
            progress: () => undefined,
          }
        : undefined
    );
  }

  /** An invite from someone on the local network (`LanNearby`): true once the person accepted it. */
  lanInvite(
    invite: { invite: string; requestId: string; senderName?: string | undefined },
    signal: AbortSignal
  ): Promise<boolean> {
    return this.#hold({ ...invite, surfaceId: this.#surfaceId() }, signal);
  }

  /** Holds an invite for the connect card until the person answers or the sender gives up. */
  #hold(
    offer: {
      invite: string;
      requestId: string;
      senderName?: string | undefined;
      surfaceId: string | undefined;
    },
    signal: AbortSignal
  ): Promise<boolean> {
    if (signal.aborted || this.#offers.size >= 4) return Promise.resolve(false);
    return new Promise((resolve) => {
      const decide = (accept: boolean) => {
        if (this.#offers.get(offer.requestId) !== held) return;
        this.#offers.delete(offer.requestId);
        signal.removeEventListener("abort", abort);
        this.#changed();
        resolve(accept);
      };
      const abort = () => decide(false);
      const held: HeldOffer = {
        decide,
        value: {
          invite: offer.invite,
          requestId: offer.requestId,
          ...(offer.senderName ? { senderName: offer.senderName.slice(0, 160) } : {}),
          ...(offer.surfaceId ? { surfaceId: offer.surfaceId } : {}),
        },
      };
      this.#offers.set(offer.requestId, held);
      signal.addEventListener("abort", abort, { once: true });
      this.#changed();
    });
  }

  /** The sender's changes; only this service's own scan and sends move its state. */
  onOperation(operation: AirDropOperation) {
    if (operation.operationId !== this.#operationId) return;
    if (operation.kind === "find") {
      this.#airDropPeers = (operation.peers ?? [])
        .filter((peer) => peer.model === airDropReceiverModel && !peer.error)
        .map((peer) => ({
          id: peer.id,
          name: (peer.name ?? "").slice(0, 160),
          via: "airdrop" as const,
        }));
      if (operation.status === "running") this.#peersChanged();
      else this.#scanEnded("airdrop", operation.status !== "succeeded");
    } else if (operation.status !== "running" && operation.peerId) {
      this.#setAsk(
        operation.peerId,
        operation.status === "succeeded" ? "accepted" : "unanswered"
      );
    }
  }

  /** A session change forgets the scan, the asks and every held offer. */
  reset() {
    this.#generation += 1;
    for (const offer of this.#offers.values()) offer.decide(false);
    this.#operationId = undefined;
    this.#airDropPeers = [];
    this.#lanPeers.clear();
    this.#scanning.clear();
    this.#failed = false;
    this.#change({ scan: "idle", peers: [], asks: [] });
  }

  /** Whether the AirDrop scan of the last find failed. */
  #failed = false;

  async #scan() {
    this.#scanning.add("airdrop");
    try {
      this.#operationId = this.#sender.find().operationId;
      await this.#sender.idle();
    } catch (error) {
      this.#scanEnded("airdrop", true);
      throw error;
    }
  }

  #scanEnded(which: "airdrop" | "lan", failed = false) {
    if (which === "airdrop") this.#failed = failed;
    this.#scanning.delete(which);
    this.#peersChanged();
  }

  /**
   * One row a receiver: a local network receiver whose AirDrop id this round's
   * AirDrop scan found is that same row. Names are not identity: two receivers
   * with one name stay two rows.
   */
  #peersChanged() {
    const found = new Set(this.#airDropPeers.map((peer) => peer.id));
    const lan = [...this.#lanPeers.entries()]
      .filter(([, service]) => !service.airDrop || !found.has(service.airDrop))
      .map(([id, service]) => ({
        id,
        name: service.name.slice(0, 160),
        via: "wifi" as const,
      }));
    this.#change({
      peers: [...this.#airDropPeers, ...lan].slice(0, 64),
      scan: this.#scanning.size
        ? "scanning"
        : this.#failed && !this.#lan
          ? "failed"
          : "done",
    });
  }

  #setAsk(peerId: string, status: NearbyState["asks"][number]["status"]) {
    this.#change({
      asks: [
        ...this.#state.asks.filter((ask) => ask.peerId !== peerId),
        { peerId, status },
      ].slice(-64),
    });
  }

  #change(patch: Partial<NearbyState>) {
    this.#state = { ...this.#state, ...patch };
    this.#changed();
  }

  #changed() {
    this.#state = { ...this.#state, revision: this.#state.revision + 1 };
    this.#publish(this.state());
  }

  /**
   * The session boundary every scan and send of either way keeps: the returned
   * check throws once the session of `generation` has ended. Each step that
   * waited (a scan, the sender's name) checks it before it sends or writes state.
   */
  #current(generation: number) {
    return () => {
      if (generation !== this.#generation) throw new Error("The session changed.");
    };
  }

  /**
   * Runs `operation` after the scans and sends before it, unless the session
   * changed meanwhile; `current` throws once it has, for checks after a wait.
   */
  #serialize<T>(operation: (current: () => void) => Promise<T>): Promise<T> {
    const current = this.#current(this.#generation);
    // A send or scan another caller runs finishes first.
    const result = this.#queue
      .then(() => this.#sender.idle())
      .then(() => {
        current();
        return operation(current);
      });
    this.#queue = result.catch(() => undefined);
    return result;
  }
}

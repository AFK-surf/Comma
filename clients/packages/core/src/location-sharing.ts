// Location sharing: whether this device sends its position with each message the person sends, so the Agent knows
// where they are without asking. Off until the person turns it on; the account database on this device keeps the
// choice (`location:share`), so each device decides for itself.
//
// - The phone reads its position while the app is in front and sharing is on, and gives each reading to the core
//   (`locationSharing.report`). It gives `null` when the app leaves the front, so a position never outlives the time
//   the phone could follow the person.
// - The core keeps only the newest reading, in memory. Each message sent while one is held carries it as
//   `client_location`, with when it was read; turning sharing off or another account forgets it at once.
import { CoreError, type Value } from "@comma/core-kernel";
import { DateTime, Effect } from "effect";
import { z } from "zod";
import type { LocationSharingValue } from "./contract.ts";
import type { Ctx } from "./ctx.ts";

const SHARE = "location:share";

/** A position as a message carries it to the server. */
export interface ClientLocation {
  latitude: number;
  longitude: number;
  /** Metres, as the phone reported it. */
  accuracy_m?: number;
  /** When the phone read it, ISO 8601. */
  read_at: string;
}

const reportSchema = z.object({
  position: z
    .object({
      latitude: z.number().min(-90).max(90),
      longitude: z.number().min(-180).max(180),
      accuracy: z.number().nonnegative().finite().nullish(),
      /** Epoch ms. */
      readAt: z.number().int().positive(),
    })
    .nullable(),
});

export class LocationSharing {
  readonly #ctx: Ctx;
  #position: ClientLocation | null = null;
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    const { kernel } = ctx;
    kernel.source("locationSharing", {
      // Nothing to follow: the value changes only by this device's own calls.
      start: () => undefined,
      stop: () => undefined,
      compute: (): Value => ({
        ok: { enabled: this.#enabled() } satisfies LocationSharingValue,
      }),
    });
    // Another account starts with nothing of this one's.
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#position = null;
      this.#invalidate();
    });
    kernel.calls({
      "locationSharing.set": {
        doing: true,
        run: (p) =>
          Effect.suspend(() => {
            const enabled = (p as { enabled?: unknown } | null)?.enabled;
            if (typeof enabled !== "boolean")
              return Effect.fail(CoreError.invalid("enabled is a boolean"));
            const account = ctx.session.current();
            if (!account)
              return Effect.fail(CoreError.invalid("no account is signed in"));
            account.setMeta(SHARE, enabled);
            if (!enabled) this.#position = null;
            this.#invalidate();
            return Effect.succeed(null);
          }),
      },
      "locationSharing.report": {
        run: (p) =>
          Effect.suspend(() => {
            const input = reportSchema.safeParse(p);
            if (!input.success)
              return Effect.fail(CoreError.invalid("position is not a position"));
            const position = input.data.position;
            this.#position =
              position && this.#enabled()
                ? {
                    latitude: position.latitude,
                    longitude: position.longitude,
                    ...(position.accuracy != null
                      ? { accuracy_m: position.accuracy }
                      : {}),
                    read_at: DateTime.formatIso(DateTime.makeUnsafe(position.readAt)),
                  }
                : null;
            return Effect.succeed(null);
          }),
      },
    });
  }

  /** The position a message sent now carries, if sharing is on and the phone gave one. */
  current(): ClientLocation | undefined {
    return this.#enabled() ? (this.#position ?? undefined) : undefined;
  }

  #enabled(): boolean {
    return this.#ctx.session.current()?.meta<boolean>(SHARE) === true;
  }

  #invalidate(): void {
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "locationSharing") store.invalidate(topic);
  }
}

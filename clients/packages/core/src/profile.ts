// The signed-in account's profile: kept on the device (`doc` "profile"), read again whenever a surface first shows it
// and on `profile.refresh`. A change (a name, a language, an avatar or its removal) shows on every surface the moment
// it is asked for: the profile shows it until the server answers, then the saved profile; one the server refuses goes
// back to what was saved, and its call fails. A new avatar shows from its bytes while it uploads: the profile names it
// `pending-<n>`, which `files.read` answers from here.
//
// Bounds: one read in flight; one save at a time, in the order asked (each one request); the bytes of an avatar are
// held while its upload waits or runs.
import { CoreError, Priority, type Value } from "@comma/core-kernel";
import { Effect, Option, Semaphore } from "effect";
import { profileSchema } from "./comma/schemas.ts";
import type { FileBytes, Profile, ProfileValue } from "./contract.ts";
import { API_LANE, type Ctx, Live } from "./ctx.ts";
import type { Account } from "./account.ts";

const DOC = "profile";
const PATH = "/v1/comma/me/profile";
const MAX_AVATAR_BYTES = 10 * 1024 * 1024;
/** The name the profile gives an avatar on its way up; the server's revisions never have it. */
const PENDING_AVATAR = "pending-";

/** A change shown before the server answers: the newest one of each field, which an older answer leaves in place. */
type Pending<T> = { change: number; value: T };
/** An avatar on its way up, or its removal (null). */
type PendingAvatar = { revision: string; bytes: Uint8Array; type: string } | null;

export class Profiles {
  readonly #ctx: Ctx;
  readonly #live: Live;
  #failed = false;
  #accountKey: string | null = null;
  /** Saves go one at a time, in the order asked: the server ends on the last change. */
  readonly #writes = Semaphore.makeUnsafe(1);
  #changes = 0;
  #name: Pending<string> | undefined;
  #locale: Pending<string> | undefined;
  #avatar: Pending<PendingAvatar> | undefined;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("profile", {
      start: (topic) => this.#live.run(topic, this.#quietRead(Priority.shown)),
      stop: (topic) => this.#live.stop(topic),
      compute: (): Value => ({ ok: this.#value() }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#failed = false;
      this.#name = this.#locale = this.#avatar = undefined;
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "profile") continue;
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#quietRead(Priority.shown));
      }
    });
    kernel.calls({
      "profile.refresh": {
        run: () => this.#read(Priority.asked).pipe(Effect.as(null)),
      },
      "profile.update": {
        run: (p) => {
          const params = (p ?? {}) as { name?: unknown; locale?: unknown };
          const attrs: { name?: string; locale?: string } = {};
          if (params.name !== undefined) {
            if (
              typeof params.name !== "string" ||
              !params.name.trim() ||
              params.name.trim().length > 64
            )
              throw CoreError.invalid("name must be 1 to 64 characters");
            attrs.name = params.name.trim();
          }
          if (params.locale !== undefined) {
            if (
              typeof params.locale !== "string" ||
              !params.locale ||
              params.locale.length > 16
            )
              throw CoreError.invalid("locale is invalid");
            attrs.locale = params.locale;
          }
          if (!attrs.name && !attrs.locale)
            throw CoreError.invalid("name or locale is required");
          const change = ++this.#changes;
          if (attrs.name !== undefined) this.#name = { change, value: attrs.name };
          if (attrs.locale !== undefined)
            this.#locale = { change, value: attrs.locale };
          return this.#save(change, (account) =>
            ctx.api.request(account, "PATCH", PATH, profileSchema, attrs)
          );
        },
      },
      "profile.uploadAvatar": {
        run: (p) => {
          const params = (p ?? {}) as {
            bytes?: unknown;
            type?: unknown;
            name?: unknown;
          };
          if (
            !(params.bytes instanceof Uint8Array) ||
            params.bytes.length === 0 ||
            params.bytes.length > MAX_AVATAR_BYTES
          )
            throw CoreError.invalid("bytes must be an image of at most 10 MB");
          const type =
            typeof params.type === "string" && params.type
              ? params.type
              : "application/octet-stream";
          const name =
            typeof params.name === "string" && params.name ? params.name : "avatar";
          const bytes = params.bytes;
          const change = ++this.#changes;
          this.#avatar = {
            change,
            value: { revision: `${PENDING_AVATAR}${change}`, bytes, type },
          };
          return this.#save(change, (account) =>
            ctx.api.upload(account, "PUT", "/v1/comma/me/avatar", profileSchema, {
              field: "avatar",
              name,
              type,
              bytes,
            })
          );
        },
      },
      "profile.removeAvatar": {
        run: () => {
          const change = ++this.#changes;
          this.#avatar = { change, value: null };
          return this.#save(change, (account) =>
            ctx.api.request(account, "DELETE", "/v1/comma/me/avatar", profileSchema)
          );
        },
      },
    });
  }

  /**
   * The bytes of the avatar on its way up that the profile names `revision`, for `files.read`. One that has since
   * settled is not on the server under that name: its read fails here, and the profile names what was saved.
   */
  pendingAvatar(revision: string): FileBytes | undefined {
    const avatar = this.#avatar?.value;
    if (avatar?.revision === revision)
      return { bytes: avatar.bytes, type: avatar.type };
    if (revision.startsWith(PENDING_AVATAR))
      throw new CoreError("not_found", "The avatar upload has settled.");
    return undefined;
  }

  #value(): ProfileValue {
    const kept = this.#ctx.session.current()?.doc<Profile>(DOC);
    if (!kept) return { status: this.#failed ? "error" : "loading", profile: null };
    const profile = { ...kept.value };
    if (this.#name) profile.name = this.#name.value;
    if (this.#locale) profile.locale = this.#locale.value;
    if (this.#avatar) profile.avatar_id = this.#avatar.value?.revision ?? null;
    return { status: "ready", profile };
  }

  /** The change `change` was answered: what it showed goes, unless a newer change of the field shows instead. */
  #settle(change: number): void {
    if (this.#name?.change === change) this.#name = undefined;
    if (this.#locale?.change === change) this.#locale = undefined;
    if (this.#avatar?.change === change) this.#avatar = undefined;
    this.#invalidate();
  }

  #invalidate(): void {
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "profile") store.invalidate(topic);
  }

  #keep(account: Account, profile: Profile): void {
    this.#failed = false;
    account.putDoc(DOC, profile, this.#ctx.now());
    this.#invalidate();
  }

  #quietRead(priority: number): Effect.Effect<void> {
    return this.#read(priority).pipe(Effect.ignore);
  }

  #read(priority: number): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    return Effect.gen({ self: this }, function* () {
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      yield* ctx.scheduler.ask(
        API_LANE,
        `${account.value.dbName}:${DOC}`,
        priority,
        ctx.api.request(account.value, "GET", PATH, profileSchema).pipe(
          Effect.tap((profile) =>
            Effect.sync(() => this.#keep(account.value, profile as Profile))
          ),
          Effect.tapError(() =>
            Effect.sync(() => {
              this.#failed = true;
              this.#invalidate();
            })
          )
        )
      );
    });
  }

  /** Sends change `change`, shown from now on: the saved profile replaces it, a refusal takes it back. */
  #save(
    change: number,
    send: (account: Account) => Effect.Effect<unknown, CoreError>
  ): Effect.Effect<Profile, CoreError> {
    const ctx = this.#ctx;
    this.#invalidate();
    return this.#writes
      .withPermits(1)(
        ctx.session.account().pipe(
          Effect.flatMap((account) =>
            send(account).pipe(
              Effect.map((saved) => saved as Profile),
              Effect.tap((saved) => Effect.sync(() => this.#keep(account, saved)))
            )
          )
        )
      )
      .pipe(Effect.ensuring(Effect.sync(() => this.#settle(change))));
  }
}

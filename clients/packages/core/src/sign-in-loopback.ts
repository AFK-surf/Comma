// Sign-ins a browser finishes by coming back to this computer (the desktop app's loopback listener, `DesktopPorts`):
// a Codex or Claude subscription's OAuth (`models.signIn.loopback`), and TokenDance's key (`models.tokenDance.connect`),
// saved as one profile serving every chat model TokenDance lists. Each call opens the listener, starts the sign-in,
// opens the system browser and waits for the browser to come back with the state it was sent; it shows that browser
// a page (received, denied, or invalid for any other state) and brings the app to the front. Cancelled with the call,
// the listener closes. A TokenDance key stays in the core: no call answers it and no topic shows it.
//
// Bounds: one sign-in of each kind at a time per device; a subscription waits 15 minutes for the browser, TokenDance
// 10; one request per step (begin, finish; TokenDance: the key's exchange, the model list, the profile).
import { CoreError, fromUtf8, utf8 } from "@comma/core-kernel";
import { Effect, Option, Semaphore, Stream, type Scope } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { modelProfileSchema, subscriptionSignInSchema } from "./comma/schemas.ts";
import type { ModelProfile } from "./contract.ts";
import type { Ctx } from "./ctx.ts";
import type { DesktopPorts, Loopback } from "./host.ts";
import type { Models } from "./models.ts";

const SUBSCRIPTION_WAIT_MS = 900_000;
const TOKENDANCE_WAIT_MS = 600_000;
const TOKENDANCE_EXCHANGE_MS = 15_000;
const TOKENDANCE = "https://tokendance.space";
const TOKENDANCE_GATEWAY = `${TOKENDANCE}/gateway/v1`;
/** The most model ids one profile keeps, as the backend bounds them. */
const MAX_PROFILE_MODELS = 500;

const subscriptionCallbacks = {
  codex: {
    port: 1455,
    path: "/auth/callback",
    origin: "https://auth.openai.com",
  },
  claude: { port: 54545, path: "/callback", origin: "https://claude.ai" },
} as const;

const keySchema = z.object({ key: z.string().min(1).max(8192) });
/** The models TokenDance's gateway lists, with the protocols each speaks. */
const listedSchema = z.object({
  data: z
    .array(
      z.object({
        id: z.string(),
        supported_protocols: z.array(z.string()).optional(),
      })
    )
    .max(1000),
});

const failed = (code: string, message: string) => () => new CoreError(code, message);

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

/** A required string parameter. */
const text = (raw: unknown, name: string, max = 256) => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (typeof v !== "string" || !v || v.length > max)
    throw CoreError.invalid(`${name} is required`);
  return v;
};
/** An optional string parameter. */
const optional = (raw: unknown, name: string) => {
  const v = (raw as Record<string, unknown> | null)?.[name];
  if (v === undefined || v === "") return undefined;
  if (typeof v !== "string" || v.length > 256)
    throw CoreError.invalid(`${name} is a string`);
  return v;
};

export class LoopbackSignIns {
  readonly #ctx: Ctx;
  readonly #models: Models;
  /** One sign-in of each kind at a time: a second while one holds the permit fails at once. */
  readonly #permits = {
    subscription: Semaphore.makeUnsafe(1),
    tokenDance: Semaphore.makeUnsafe(1),
  };

  constructor(ctx: Ctx, models: Models) {
    this.#ctx = ctx;
    this.#models = models;
    ctx.kernel.calls({
      "models.signIn.loopback": {
        cancellable: true,
        run: (p) => {
          const workspace = text(p, "workspace");
          const provider = text(p, "provider");
          if (provider !== "codex" && provider !== "claude")
            throw CoreError.invalid("provider is codex or claude");
          const account = optional(p, "account");
          const version = optional(p, "version");
          return this.#subscription(
            workspace,
            provider,
            account && version ? { account_id: account, version } : undefined
          );
        },
      },
      "models.tokenDance.connect": {
        cancellable: true,
        run: (p) => this.#tokenDance(text(p, "workspace"), text(p, "name", 200).trim()),
      },
    });
  }

  /** Runs `work` as the one sign-in of `kind`, on the desktop's ports, for the account signed in now. */
  #one<A>(
    kind: "subscription" | "tokenDance",
    work: (
      desktop: DesktopPorts,
      account: Account
    ) => Effect.Effect<A, CoreError, never>
  ): Effect.Effect<A, CoreError> {
    return Effect.suspend(() => {
      const desktop = this.#ctx.host.desktop;
      if (!desktop)
        return Effect.fail(
          new CoreError("unsupported", "Only the desktop app signs in this way.")
        );
      return this.#ctx.session.account().pipe(
        Effect.flatMap((account) =>
          work(desktop, account).pipe(
            // The session ending ends the sign-in: what came back is no longer this account's.
            Effect.raceFirst(
              this.#sessionEnded(account).pipe(
                Effect.andThen(
                  Effect.fail(
                    new CoreError("authorization_expired", "The session ended.")
                  )
                )
              )
            )
          )
        ),
        this.#permits[kind].withPermitsIfAvailable(1),
        Effect.flatMap(
          Option.match({
            onNone: () =>
              Effect.fail(
                new CoreError("authorization_in_progress", "A sign-in is under way.")
              ),
            onSome: Effect.succeed,
          })
        )
      );
    });
  }

  /** Done once `account`'s session is no longer the one signed in (signed out, or another took its place). */
  #sessionEnded(account: Account): Effect.Effect<void> {
    const { session } = this.#ctx;
    const ended = () => {
      const now = session.lease();
      return (
        !now ||
        now.sessionId !== account.lease.sessionId ||
        now.audience !== account.lease.audience
      );
    };
    return Effect.raceFirst(
      session.closed(account.lease),
      Effect.callback<void>((resume) => {
        if (ended()) return resume(Effect.void);
        const stop = session.onChange(() => {
          if (ended()) resume(Effect.void);
        });
        return Effect.sync(stop);
      })
    );
  }

  /** Opens the loopback listener: `authorization_port_in_use` when another app holds the port. */
  #listen(
    desktop: DesktopPorts,
    input: Parameters<DesktopPorts["listen"]>[0]
  ): Effect.Effect<Loopback, CoreError, Scope.Scope> {
    return desktop
      .listen(input)
      .pipe(
        Effect.mapError((e) =>
          e.message === "authorization_port_in_use"
            ? new CoreError(
                "authorization_port_in_use",
                "The sign-in's port is in use."
              )
            : new CoreError("authorization_failed", e.message)
        )
      );
  }

  /**
   * Waits for the browser to come back with `state` (the only one, and a single code): its address. Another state is
   * shown the invalid page and waited past; a denial is shown its page and fails `authorization_denied`.
   */
  #callback(
    desktop: DesktopPorts,
    loopback: Loopback,
    state: string,
    waitMs: number
  ): Effect.Effect<URL, CoreError> {
    // Each visit in turn, until one carries the state: it ends the stream.
    return Stream.fromEffectRepeat(loopback.next).pipe(
      Stream.mapError((e) => new CoreError("authorization_failed", e.message)),
      Stream.mapEffect((visit): Effect.Effect<Option.Option<URL>, CoreError> => {
        const url = new URL(visit.url);
        const states = url.searchParams.getAll("state");
        if (states.length !== 1 || states[0] !== state)
          return visit.reply("invalid").pipe(Effect.as(Option.none()));
        if (
          url.searchParams.getAll("code").length !== 1 ||
          url.searchParams.has("error")
        )
          return visit
            .reply("denied")
            .pipe(
              Effect.andThen(desktop.returnToApp),
              Effect.andThen(
                Effect.fail(
                  new CoreError(
                    "authorization_denied",
                    "The sign-in was not completed."
                  )
                )
              )
            );
        return visit
          .reply("received")
          .pipe(Effect.andThen(desktop.returnToApp), Effect.as(Option.some(url)));
      }),
      Stream.filter(Option.isSome),
      Stream.map((returned) => returned.value),
      Stream.runHead,
      Effect.flatMap(
        Option.match({
          onNone: () =>
            Effect.fail(new CoreError("authorization_failed", "The listener closed.")),
          onSome: Effect.succeed,
        })
      ),
      Effect.timeoutOrElse({
        duration: waitMs,
        orElse: () =>
          Effect.fail(
            new CoreError(
              "authorization_expired",
              "The browser did not come back in time."
            )
          ),
      })
    );
  }

  #subscription(
    workspace: string,
    provider: "codex" | "claude",
    renew: { account_id: string; version: string } | undefined
  ): Effect.Effect<ModelProfile, CoreError> {
    const ctx = this.#ctx;
    const callback = subscriptionCallbacks[provider];
    const oauth = route`/v1/comma/workspaces/${workspace}/subscription-accounts/oauth`;
    return this.#one("subscription", (desktop, account) =>
      Effect.scoped(
        Effect.gen({ self: this }, function* () {
          const loopback = yield* this.#listen(desktop, {
            port: callback.port,
            path: callback.path,
            source: "subscription",
          });
          const begun = yield* ctx.api
            .request(account, "POST", oauth, subscriptionSignInSchema, {
              provider,
              mode: "callback",
              ...renew,
            })
            .pipe(
              Effect.mapError(
                failed("authorization_failed", "The sign-in did not start.")
              )
            );
          // The page must send the browser back here, and say which sign-in it is.
          const authorization = new URL(begun.url);
          const state = authorization.searchParams.get("state");
          if (
            authorization.origin !== callback.origin ||
            authorization.searchParams.get("redirect_uri") !==
              `http://localhost:${loopback.port}${callback.path}` ||
            !state
          )
            return yield* Effect.fail(
              new CoreError(
                "authorization_failed",
                "The sign-in's page is not the provider's."
              )
            );
          yield* desktop
            .openExternal(authorization.href)
            .pipe(
              Effect.mapError((e) => new CoreError("authorization_failed", e.message))
            );
          const returned = yield* this.#callback(
            desktop,
            loopback,
            state,
            SUBSCRIPTION_WAIT_MS
          );
          const profile = yield* ctx.api
            .request(
              account,
              "POST",
              `${oauth}/${encodeURIComponent(begun.id)}`,
              modelProfileSchema,
              { code: returned.href }
            )
            .pipe(
              Effect.mapError(
                failed("authorization_failed", "The sign-in did not finish.")
              )
            );
          yield* this.#models.reloadProfiles(workspace);
          return profile as ModelProfile;
        })
      )
    );
  }

  #tokenDance(workspace: string, name: string): Effect.Effect<ModelProfile, CoreError> {
    const ctx = this.#ctx;
    return this.#one("tokenDance", (desktop, account) =>
      Effect.scoped(
        Effect.gen({ self: this }, function* () {
          if (!name) return yield* Effect.fail(CoreError.invalid("name is required"));
          // TokenDance's exchange is no standard OAuth token answer: PKCE (S256) keeps an intercepted code from
          // yielding a key, and a callback with another state exchanges nothing.
          const random = () => {
            const bytes = new Uint8Array(32);
            ctx.host.randomBytes(bytes);
            return base64url(bytes);
          };
          const verifier = random();
          const state = random();
          const challenge = base64url(
            yield* desktop
              .sha256(verifier)
              .pipe(
                Effect.mapError((e) => new CoreError("authorization_failed", e.message))
              )
          );
          const loopback = yield* this.#listen(desktop, {
            port: 0,
            path: "/callback",
            source: "byok",
          });
          const callback = new URL(`http://127.0.0.1:${loopback.port}/callback`);
          callback.searchParams.set("state", state);
          const authorization = new URL(`${TOKENDANCE}/auth`);
          authorization.searchParams.set("callback_url", callback.href);
          authorization.searchParams.set("code_challenge", challenge);
          authorization.searchParams.set("code_challenge_method", "S256");
          authorization.searchParams.set("app_url", `app://${desktop.app.urlScheme}`);
          authorization.searchParams.set("key_name", desktop.app.productName);
          yield* desktop
            .openExternal(authorization.href)
            .pipe(
              Effect.mapError((e) => new CoreError("authorization_failed", e.message))
            );
          const returned = yield* this.#callback(
            desktop,
            loopback,
            state,
            TOKENDANCE_WAIT_MS
          );
          const exchanged = yield* desktop
            .providerFetch({
              url: `${TOKENDANCE}/portal/api/v1/auth/keys`,
              method: "POST",
              headers: [["content-type", "application/json"]],
              body: utf8(
                JSON.stringify({
                  code: returned.searchParams.get("code"),
                  code_verifier: verifier,
                  code_challenge_method: "S256",
                })
              ),
              maxBytes: 16_384,
            })
            .pipe(
              Effect.timeout(TOKENDANCE_EXCHANGE_MS),
              Effect.mapError(failed("authorization_failed", "TokenDance gave no key."))
            );
          // The provider's own words never reach a UI.
          const key = (() => {
            if (exchanged.status < 200 || exchanged.status >= 300) return null;
            try {
              const parsed = keySchema.safeParse(JSON.parse(fromUtf8(exchanged.body)));
              return parsed.success ? parsed.data.key : null;
            } catch {
              return null;
            }
          })();
          if (!key)
            return yield* Effect.fail(
              new CoreError("authorization_failed", "TokenDance gave no key.")
            );
          const listed = yield* ctx.api
            .request(
              account,
              "POST",
              route`/v1/comma/workspaces/${workspace}/model-discovery`,
              listedSchema,
              { base_url: TOKENDANCE_GATEWAY, api_key: key, protocol: "responses" }
            )
            .pipe(
              Effect.mapError(
                failed("authorization_failed", "TokenDance lists no models.")
              )
            );
          // The profile serves every chat model TokenDance lists; Agents pick among them. Chat Completions is the one
          // protocol nearly all of them speak.
          const encoder = new TextEncoder();
          const models = listed.data
            .filter(
              (entry) =>
                !entry.supported_protocols ||
                entry.supported_protocols.includes("chat_completions")
            )
            .map((entry) => entry.id)
            .filter((id) => id && encoder.encode(id).length <= 200)
            .slice(0, MAX_PROFILE_MODELS);
          if (!models.length)
            return yield* Effect.fail(
              new CoreError(
                "invalid_model_configuration",
                "TokenDance lists no chat model."
              )
            );
          const profile = yield* ctx.api
            .request(
              account,
              "POST",
              route`/v1/comma/workspaces/${workspace}/subscription-accounts`,
              modelProfileSchema,
              {
                credential_kind: "provider_api_key",
                source: "custom",
                name,
                api_key: key,
                base_url: TOKENDANCE_GATEWAY,
                protocol: "chat_completions",
                models,
              }
            )
            .pipe(
              Effect.mapError(failed("model_save_failed", "The profile was not saved."))
            );
          yield* this.#models.reloadProfiles(workspace);
          return profile as ModelProfile;
        })
      )
    );
  }
}

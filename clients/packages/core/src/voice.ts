// Settings › Voice: the caller numbers verified for a workspace's voice line (each proved by an SMS code, optionally
// guarded by a PIN), the voice agent API keys that custom voice clients connect with, and whether voice calls are
// available now. Read while the page shows them; the two halves are read and fail independently. A number change
// answers the new numbers; a key change reads the keys again. A new key's plaintext is answered to the caller only.
//
// Bounds: one read per page shown, two requests (numbers, keys); each change is one request (keys: then one read).
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import { DateTime, Effect, Option } from "effect";
import { z } from "zod";
import { route } from "./api.ts";
import {
  voiceIntegrationSchema,
  voiceKeyCreatedSchema,
  voiceKeySchema,
  voiceVerificationSchema,
} from "./comma/schemas.ts";
import type { VoiceIntegration, VoiceKeyCreated, VoiceValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import type { Workspaces } from "./workspaces.ts";

const keysPath = (ws: string) => route`/v1/comma/workspaces/${ws}/voice-api-keys`;
const linePath = (ws: string) => route`/v1/comma/workspaces/${ws}/integrations/voice`;

const params = {
  string(raw: unknown, name: string, max = 256): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  optional(raw: unknown, name: string): string | undefined {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (v === undefined || v === "") return undefined;
    if (typeof v !== "string" || v.length > 64)
      throw CoreError.invalid(`${name} is a string`);
    return v;
  },
};

const empty = (): VoiceValue => ({
  workspace: null,
  integration: null,
  keys: null,
  integrationError: false,
  keysError: false,
});

export class Voice {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  readonly #shown = new Map<string, VoiceValue>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("voice", {
      start: (topic) => this.#live.run(topic, this.#load(topic)),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(String(topic.prefer ?? ""));
      },
      compute: (topic): Value => ({
        ok: this.#shown.get(String(topic.prefer ?? "")) ?? empty(),
      }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#shown.clear();
      for (const topic of this.#topics()) {
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#load(topic));
      }
    });

    const number = (
      p: unknown,
      method: "POST" | "PUT" | "DELETE",
      to: string,
      body?: unknown
    ) => {
      const workspace = params.string(p, "workspace");
      return this.#send(method, to, voiceIntegrationSchema, body).pipe(
        Effect.tap((integration) =>
          Effect.sync(() => this.#setIntegration(workspace, integration))
        ),
        Effect.as(null)
      );
    };
    kernel.calls({
      "voice.refresh": {
        run: () =>
          Effect.forEach(this.#topics(), (t) => this.#load(t)).pipe(Effect.as(null)),
      },
      "voice.startVerification": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const e164 = params.string(p, "e164", 32);
          const line = params.optional(p, "line");
          return this.#send(
            "POST",
            `${linePath(workspace)}/numbers/verify-start`,
            voiceVerificationSchema,
            {
              e164,
              ...(line ? { line } : {}),
            }
          ).pipe(Effect.as(null));
        },
      },
      "voice.checkCode": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const e164 = params.string(p, "e164", 32);
          const code = params.string(p, "code", 16);
          const line = params.optional(p, "line");
          return number(p, "POST", `${linePath(workspace)}/numbers/verify-check`, {
            e164,
            code,
            ...(line ? { line } : {}),
          });
        },
      },
      "voice.setPin": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const e164 = params.string(p, "e164", 32);
          const pin = (p as { pin?: unknown } | null)?.pin;
          if (typeof pin !== "string" || pin.length > 16)
            throw CoreError.invalid("pin is a string");
          return number(p, "PUT", `${linePath(workspace)}/pin`, { e164, pin });
        },
      },
      "voice.removeNumber": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const e164 = params.string(p, "e164", 32);
          return number(
            p,
            "DELETE",
            `${linePath(workspace)}/numbers/${encodeURIComponent(e164)}`
          );
        },
      },
      "voice.createKey": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const name = params.string(p, "name", 128).trim();
          const expiresAt = (p as { expiresAt?: unknown } | null)?.expiresAt;
          if (
            expiresAt !== undefined &&
            (typeof expiresAt !== "number" ||
              !Number.isSafeInteger(expiresAt) ||
              expiresAt <= 0)
          )
            throw CoreError.invalid("expiresAt is epoch seconds");
          return this.#send("POST", keysPath(workspace), voiceKeyCreatedSchema, {
            name,
            ...(expiresAt === undefined
              ? {}
              : {
                  expires_at: DateTime.formatIso(DateTime.makeUnsafe(expiresAt * 1000)),
                }),
          }).pipe(
            Effect.tap(() => this.#reread()),
            Effect.map((created): VoiceKeyCreated => created)
          );
        },
      },
      "voice.updateKey": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const key = params.string(p, "key");
          const name = params.optional(p, "name");
          const status = (p as { status?: unknown } | null)?.status;
          if (status !== undefined && status !== "active" && status !== "disabled")
            throw CoreError.invalid("status is active or disabled");
          return this.#send(
            "PATCH",
            `${keysPath(workspace)}/${encodeURIComponent(key)}`,
            voiceKeySchema,
            {
              ...(name ? { name } : {}),
              ...(status ? { status } : {}),
            }
          ).pipe(
            Effect.tap(() => this.#reread()),
            Effect.as(null)
          );
        },
      },
      "voice.deleteKey": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const key = params.string(p, "key");
          return this.#send(
            "DELETE",
            `${keysPath(workspace)}/${encodeURIComponent(key)}`,
            z.object({ deleted: z.boolean() })
          ).pipe(
            Effect.tap(() => this.#reread()),
            Effect.as(null)
          );
        },
      },
    });
  }

  #topics(): Topic[] {
    return this.#ctx.kernel.store.liveTopics().filter((t) => t.topic === "voice");
  }

  #send<S extends z.ZodType>(
    method: "POST" | "PUT" | "PATCH" | "DELETE",
    path: string,
    schema: S,
    body?: unknown
  ) {
    const ctx = this.#ctx;
    return ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) =>
          ctx.api.request(account, method, path, schema, body)
        )
      );
  }

  #publish(prefer: string, next: VoiceValue): void {
    this.#shown.set(prefer, next);
    for (const topic of this.#topics())
      if (String(topic.prefer ?? "") === prefer)
        this.#ctx.kernel.store.invalidate(topic);
  }

  #setIntegration(workspace: string, integration: VoiceIntegration): void {
    for (const [prefer, shown] of this.#shown)
      if (shown.workspace === workspace)
        this.#publish(prefer, { ...shown, integration, integrationError: false });
  }

  /** After a key change: every shown page reads again; a failed read shows on the page. */
  #reread(): Effect.Effect<void> {
    return Effect.forEach(this.#topics(), (t) => this.#load(t)).pipe(Effect.asVoid);
  }

  #load(topic: Topic): Effect.Effect<void> {
    const prefer = String(topic.prefer ?? "");
    return Effect.gen({ self: this }, function* () {
      const ctx = this.#ctx;
      const account = yield* ctx.session.account().pipe(Effect.option);
      if (Option.isNone(account)) return;
      if (!this.#workspaces.list(account.value)?.some((w) => w.id === prefer))
        yield* this.#workspaces.refresh(Priority.shown).pipe(Effect.ignore);
      const list = this.#workspaces.list(account.value) ?? [];
      const workspace = (list.find((w) => w.id === prefer) ?? list[0])?.id ?? null;
      const was = this.#shown.get(prefer) ?? empty();
      if (!workspace) {
        this.#publish(prefer, { ...was, integrationError: true, keysError: true });
        return;
      }
      // The two halves fail apart: an unconfigured voice line must not hide the keys, nor the other way round.
      const [integration, keys] = yield* Effect.all(
        [
          ctx.api
            .request(account.value, "GET", linePath(workspace), voiceIntegrationSchema)
            .pipe(Effect.option),
          ctx.api
            .request(account.value, "GET", keysPath(workspace), z.array(voiceKeySchema))
            .pipe(Effect.option),
        ],
        { concurrency: "unbounded" }
      );
      this.#publish(prefer, {
        workspace,
        integration: Option.isSome(integration) ? integration.value : was.integration,
        keys: Option.isSome(keys) ? keys.value : was.keys,
        integrationError: Option.isNone(integration),
        keysError: Option.isNone(keys),
      });
    });
  }
}

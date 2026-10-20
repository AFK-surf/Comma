// The local server's recommendation mock (a debug setting of the dev app on a local server): whether it can be used and
// is on, read when shown and not kept after. Turning it on or off sends the account's first workspace
// (as read now) with it; a refresh asks that workspace's recommendations again.
import { CoreError, Priority, topicKey, type Value } from "@comma/core-kernel";
import { Effect, Option, Result } from "effect";
import { z } from "zod";
import type { RecommendationMockStatus, RecommendationMockValue } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import type { Recommendations } from "./recommendations.ts";
import type { Workspaces } from "./workspaces.ts";

const PATH = "/v1/debug/recommendation-mock";

const statusSchema = z.object({
  available: z.boolean(),
  enabled: z.boolean(),
  syncError: z.boolean().optional(),
});

export class RecommendationMock {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  readonly #shown = new Map<string, NonNullable<RecommendationMockValue>>();

  constructor(ctx: Ctx, workspaces: Workspaces, recommendations: Recommendations) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("recommendationMock", {
      start: (topic) =>
        this.#live.run(
          topic,
          Effect.gen({ self: this }, function* () {
            const account = yield* ctx.session.account().pipe(Effect.option);
            if (Option.isNone(account)) return;
            const answer = yield* ctx.api
              .request(account.value, "GET", PATH, statusSchema)
              .pipe(Effect.result);
            this.#shown.set(
              topicKey(topic),
              Result.isSuccess(answer)
                ? { status: "ready", ...answer.success }
                : { status: "failed" }
            );
            kernel.store.invalidate(topic);
          })
        ),
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(topicKey(topic));
      },
      compute: (topic): Value => ({ ok: this.#shown.get(topicKey(topic)) ?? null }),
    });
    kernel.calls({
      "recommendationMock.set": {
        run: (p) => {
          const enabled = (p as { enabled?: unknown } | null)?.enabled;
          if (typeof enabled !== "boolean")
            throw CoreError.invalid("enabled is required");
          return Effect.gen({ self: this }, function* () {
            const account = yield* ctx.session.account();
            const workspace = yield* this.#firstWorkspace();
            const status: RecommendationMockStatus = yield* ctx.api.request(
              account,
              "PATCH",
              PATH,
              statusSchema,
              { enabled, workspaceId: workspace }
            );
            for (const topic of kernel.store.liveTopics()) {
              if (topic.topic !== "recommendationMock") continue;
              this.#shown.set(topicKey(topic), { status: "ready", ...status });
              kernel.store.invalidate(topic);
            }
            return status;
          });
        },
      },
      "recommendationMock.refresh": {
        run: () =>
          this.#firstWorkspace().pipe(
            Effect.flatMap((workspace) =>
              workspace
                ? recommendations.refresh(workspace)
                : Effect.fail(CoreError.invalid("workspace unavailable"))
            ),
            Effect.as(null)
          ),
      },
    });
  }

  /** The account's first workspace, as read now. */
  #firstWorkspace(): Effect.Effect<string | undefined, CoreError> {
    return this.#workspaces.refresh(Priority.asked).pipe(
      Effect.flatMap(() => this.#ctx.session.account()),
      Effect.map((account) => this.#workspaces.list(account)?.[0]?.id)
    );
  }
}

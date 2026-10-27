// A Group's Task label catalog (kept on the device, `doc` "taskLabels:<group>"): its labels, the Agents' proposals
// waiting for a person, and the approval policy. One catalog per Group serves every surface that shows labels
// (Settings › Labels, the Task panel, card chips, the chat's confirmation card, an inline Task's hover card); every
// change answers the new catalog, which replaces the kept one. A policy chosen shows at once, until the server answers;
// one it refuses goes back to the saved policy, and its call fails.
//
// Bounds: one catalog read in flight per Group. A `taskLabels` topic reads when it starts (a surface opening, or its
// `key` changing: the labels it shows changed), except `known` readers, which read only while nothing is kept. The
// usage counts (`taskLabelCounts`) read the Group's first page of Tasks once per start.
import { CoreError, Priority, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option, Semaphore } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { taskLabelCatalogSchema } from "./comma/schemas.ts";
import type { TaskLabelCatalog, TaskLabelsValue } from "./contract.ts";
import { API_LANE, type Ctx, Live } from "./ctx.ts";
import type { HostedTasks } from "./hosted-tasks.ts";

const catalogDoc = (group: string) => `taskLabels:${group}`;
const labelsPath = (group: string) => route`/v1/comma/groups/${group}/task-labels`;

const assignedSchema = z.object({}).passthrough();

const countsSchema = z.object({
  data: z.array(z.object({ labels: z.array(z.string()).nullish() }).passthrough()),
});

const params = {
  string(raw: unknown, name: string): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "")
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  optional(raw: unknown, name: string): string | undefined {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (v === undefined) return undefined;
    if (typeof v !== "string" || v.length > 4096)
      throw CoreError.invalid(`${name} is a string`);
    return v;
  },
};

export class Labels {
  readonly #ctx: Ctx;
  /** Tasks Comma's server does not keep: their labels are set where they are kept. */
  hosted: HostedTasks | undefined;
  readonly #live: Live;
  /** Groups whose last read failed. */
  readonly #failed = new Set<string>();
  /** Groups with a read in flight. */
  readonly #reading = new Set<string>();
  readonly #counts = new Map<string, Record<string, number> | null>();
  /** Group → the policy chosen and not answered yet, with the choice it was (a newer one replaces it). */
  readonly #policies = new Map<string, { choice: number; policy: "ask" | "auto" }>();
  #choices = 0;
  /** Policy saves go one at a time, in the order chosen: the server ends on the last choice. */
  readonly #policyWrites = Semaphore.makeUnsafe(1);
  #accountKey: string | null = null;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("taskLabels", {
      start: (topic) => this.#live.run(topic, this.#onStart(topic)),
      stop: (topic) => this.#live.stop(topic),
      compute: (topic): Value => ({ ok: this.#value(topic.group as string) }),
    });
    kernel.source("taskLabelCounts", {
      start: (topic) => this.#live.run(topic, this.#readCounts(topic.group as string)),
      stop: (topic) => this.#live.stop(topic),
      compute: (topic): Value => ({
        ok: this.#counts.get(topic.group as string) ?? null,
      }),
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      this.#failed.clear();
      this.#reading.clear();
      this.#counts.clear();
      this.#policies.clear();
      for (const topic of kernel.store.liveTopics()) {
        if (topic.topic !== "taskLabels" && topic.topic !== "taskLabelCounts") continue;
        this.#live.stop(topic);
        kernel.store.invalidate(topic);
        this.#live.run(
          topic,
          topic.topic === "taskLabels"
            ? this.#onStart(topic)
            : this.#readCounts(topic.group as string)
        );
      }
    });

    const change = (
      p: unknown,
      method: "POST" | "PATCH" | "DELETE",
      path: (group: string) => string,
      body?: unknown
    ) => {
      const group = params.string(p, "group");
      return this.#change(group, method, path(group), body);
    };
    kernel.calls({
      "taskLabels.refresh": {
        run: (p) =>
          this.#read(params.string(p, "group"), Priority.asked).pipe(Effect.as(null)),
      },
      "taskLabels.create": {
        doing: true,
        run: (p) => {
          const name = params.string(p, "name");
          const color = params.optional(p, "color");
          const description = params.optional(p, "description");
          return change(p, "POST", labelsPath, {
            name,
            ...(color !== undefined ? { color } : {}),
            ...(description !== undefined ? { description } : {}),
          });
        },
      },
      "taskLabels.update": {
        doing: true,
        run: (p) => {
          const label = params.string(p, "label");
          const name = params.optional(p, "name");
          const color = params.optional(p, "color");
          const description = params.optional(p, "description");
          return change(
            p,
            "PATCH",
            (g) => `${labelsPath(g)}/${encodeURIComponent(label)}`,
            {
              ...(name !== undefined ? { name } : {}),
              ...(color !== undefined ? { color } : {}),
              ...(description !== undefined ? { description } : {}),
            }
          );
        },
      },
      "taskLabels.delete": {
        doing: true,
        run: (p) => {
          const label = params.string(p, "label");
          return change(
            p,
            "DELETE",
            (g) => `${labelsPath(g)}/${encodeURIComponent(label)}`
          );
        },
      },
      "taskLabels.assign": {
        doing: true,
        run: (p) => {
          const group = params.string(p, "group");
          const conversation = params.string(p, "conversation");
          const labels = (p as { labels?: unknown }).labels;
          if (
            !Array.isArray(labels) ||
            labels.length > 256 ||
            !labels.every((l) => typeof l === "string" && l !== "" && l.length <= 256)
          )
            throw CoreError.invalid("labels is a list of label ids");
          if (this.hosted?.owns(conversation))
            return this.hosted
              .setLabels(group, conversation, labels as string[])
              .pipe(Effect.as(null));
          return this.#ctx.session.account().pipe(
            Effect.flatMap((account) =>
              this.#ctx.api.request(
                account,
                "PATCH",
                route`/v1/comma/groups/${group}/conversations/${conversation}`,
                assignedSchema,
                { labels }
              )
            ),
            Effect.as(null)
          );
        },
      },
      "taskLabels.resolve": {
        doing: true,
        run: (p) => {
          const proposal = params.string(p, "proposal");
          const decision = (p as { decision?: unknown }).decision;
          if (decision !== "approve" && decision !== "reject")
            throw CoreError.invalid("decision is approve or reject");
          const auto = (p as { autoApprove?: unknown }).autoApprove === true;
          return change(
            p,
            "POST",
            (g) => `${labelsPath(g)}/proposals/${encodeURIComponent(proposal)}/resolve`,
            {
              decision,
              ...(decision === "approve" && auto ? { auto_approve: true } : {}),
            }
          );
        },
      },
      "taskLabels.setPolicy": {
        doing: true,
        run: (p) => {
          const policy = (p as { policy?: unknown }).policy;
          if (policy !== "ask" && policy !== "auto")
            throw CoreError.invalid("policy is ask or auto");
          const group = params.string(p, "group");
          const choice = ++this.#choices;
          this.#policies.set(group, { choice, policy });
          this.#invalidate(group);
          return this.#policyWrites
            .withPermits(1)(
              change(p, "PATCH", (g) => `${labelsPath(g)}/policy`, {
                approval_policy: policy,
              })
            )
            .pipe(
              Effect.ensuring(
                Effect.sync(() => {
                  if (this.#policies.get(group)?.choice !== choice) return;
                  this.#policies.delete(group);
                  this.#invalidate(group);
                })
              )
            );
        },
      },
    });
  }

  #invalidate(group: string): void {
    const { store } = this.#ctx.kernel;
    for (const topic of store.liveTopics())
      if (topic.topic === "taskLabels" && topic.group === group)
        store.invalidate(topic);
  }

  #catalog(account: Account | null, group: string): TaskLabelCatalog | null {
    return account?.doc<TaskLabelCatalog>(catalogDoc(group))?.value ?? null;
  }

  #value(group: string): TaskLabelsValue {
    const kept = this.#catalog(this.#ctx.session.current(), group);
    const chosen = this.#policies.get(group);
    const catalog = kept && chosen ? { ...kept, approval_policy: chosen.policy } : kept;
    return {
      catalog,
      error: this.#failed.has(group),
      loading: catalog === null && this.#reading.has(group),
    };
  }

  #onStart(topic: Topic): Effect.Effect<void> {
    const group = topic.group as string;
    return Effect.gen({ self: this }, function* () {
      if (topic.mode === "known") {
        const account = yield* this.#ctx.session.account().pipe(Effect.option);
        if (Option.isSome(account) && this.#catalog(account.value, group)) return;
      }
      yield* this.#read(group, Priority.shown).pipe(Effect.ignore);
    });
  }

  /** Reads the catalog: one read at a time per Group (a second ask joins it). */
  #read(group: string, priority: number): Effect.Effect<void, CoreError> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) => {
        this.#reading.add(group);
        this.#invalidate(group);
        return ctx.scheduler.ask(
          API_LANE,
          `${account.dbName}:${catalogDoc(group)}`,
          priority,
          ctx.api
            .request(account, "GET", labelsPath(group), taskLabelCatalogSchema)
            .pipe(
              Effect.tap((catalog) =>
                Effect.sync(() => {
                  this.#failed.delete(group);
                  account.putDoc(catalogDoc(group), catalog, ctx.now());
                })
              ),
              Effect.tapError(() => Effect.sync(() => this.#failed.add(group))),
              Effect.ensuring(
                Effect.sync(() => {
                  this.#reading.delete(group);
                  this.#invalidate(group);
                })
              ),
              Effect.asVoid
            )
        );
      })
    );
  }

  /** A change: the catalog it answers replaces the kept one. */
  #change(
    group: string,
    method: "POST" | "PATCH" | "DELETE",
    path: string,
    body?: unknown
  ): Effect.Effect<null, CoreError> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(account, method, path, taskLabelCatalogSchema, body).pipe(
          Effect.tap((catalog) =>
            Effect.sync(() => {
              this.#failed.delete(group);
              account.putDoc(catalogDoc(group), catalog, ctx.now());
              this.#invalidate(group);
            })
          )
        )
      ),
      Effect.as(null)
    );
  }

  /** How many of the Group's first page of Tasks carry each label; a failed read shows no counts. */
  #readCounts(group: string): Effect.Effect<void> {
    const ctx = this.#ctx;
    return ctx.session.account().pipe(
      Effect.flatMap((account) =>
        ctx.api.request(
          account,
          "GET",
          route`/v1/comma/groups/${group}/conversations`,
          countsSchema
        )
      ),
      Effect.map((page) => {
        const counts: Record<string, number> = {};
        for (const task of page.data)
          for (const id of task.labels ?? []) counts[id] = (counts[id] ?? 0) + 1;
        return counts;
      }),
      Effect.option,
      Effect.tap((counts) =>
        Effect.sync(() => {
          this.#counts.set(group, Option.getOrNull(counts));
          for (const topic of ctx.kernel.store.liveTopics())
            if (topic.topic === "taskLabelCounts" && topic.group === group)
              ctx.kernel.store.invalidate(topic);
        })
      ),
      Effect.asVoid
    );
  }
}

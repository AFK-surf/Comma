// Settings › Compute: a workspace's compute environments and workloads (one page; `after` names it), the Shell a
// person creates, and changes to a workload. While shown, it is read again every 5 s while anything is preparing or a
// creation waits for its answer, at most 60 reads per visit; with `shared` set the page drives the reads itself
// (`compute.observe`, on the local node's tick) instead.
//
// A creation and a deletion each carry a request id kept on the device (`meta`) before they are sent, so one that got
// no answer (the app quit, the network dropped) is asked again with the same id and the server does it once.
//
// Bounds: at most 60 sequential read cycles per page shown. Each cycle reads the page and at most one pending
// request or off-page workload. Each change is one request.
import { CoreError, type Topic, type Value } from "@comma/core-kernel";
import { Effect, Option, Result, Semaphore } from "effect";
import { z } from "zod";
import type { Account } from "./account.ts";
import { route } from "./api.ts";
import { computeProjectionSchema, computeWorkloadSchema } from "./comma/schemas.ts";
import type { ComputeValue, ComputeWorkload } from "./contract.ts";
import { type Ctx, Live } from "./ctx.ts";
import type { Workspaces } from "./workspaces.ts";

const EVERY_MS = 5_000;

const base = (ws: string) => route`/v1/comma/workspaces/${ws}/compute`;
const workloadPath = (ws: string, id: string) =>
  `${base(ws)}/workloads/${encodeURIComponent(id)}`;
const answerSchema = z.object({ workload: computeWorkloadSchema });

type Creation = { requestId: string; environmentId: string; name?: string };
const creationKey = (ws: string) => `computeCreation:${ws}`;
const deletionKey = (ws: string, id: string) => `computeDeletion:${ws}:${id}`;

const preparing = (w: ComputeWorkload) =>
  (!!w.deletion && !["complete", "cloud_retired"].includes(w.deletion.phase)) ||
  (w.desired_state === "ready" &&
    ["waiting_connection", "allocating", "starting"].includes(w.phase ?? ""));

const currentWorkload = (w: ComputeWorkload) =>
  !["deleted", "cloud_retired"].includes(w.phase ?? "") &&
  !["complete", "cloud_retired"].includes(w.deletion?.phase ?? "");

type Shown = ComputeValue & { reads: number; lock: Semaphore.Semaphore };

const params = {
  string(raw: unknown, name: string, max = 160): string {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "string" || v === "" || v.length > max)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
  int(raw: unknown, name: string): number {
    const v = (raw as Record<string, unknown> | null)?.[name];
    if (typeof v !== "number" || !Number.isInteger(v) || v < 1)
      throw CoreError.invalid(`${name} is required`);
    return v;
  },
};

const keyOf = (topic: Topic) =>
  `${topic.prefer ?? ""}\n${topic.after ?? ""}\n${topic.shared ?? ""}`;

export class Compute {
  readonly #ctx: Ctx;
  readonly #workspaces: Workspaces;
  readonly #live: Live;
  readonly #shown = new Map<string, Shown>();
  #accountKey: string | null = null;

  constructor(ctx: Ctx, workspaces: Workspaces) {
    this.#ctx = ctx;
    this.#workspaces = workspaces;
    this.#live = new Live(ctx.runner);
    const { kernel } = ctx;
    kernel.source("compute", {
      start: (topic) => {
        this.#shown.set(keyOf(topic), Compute.#empty());
        this.#live.run(topic, this.#keep(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(keyOf(topic));
      },
      compute: (topic): Value => {
        const {
          reads: _r,
          lock: _l,
          ...value
        } = this.#shown.get(keyOf(topic)) ?? Compute.#empty();
        return { ok: value };
      },
    });
    ctx.session.onChange(() => {
      const key = ctx.session.accountKey();
      if (key === this.#accountKey) return;
      this.#accountKey = key;
      for (const topic of this.#topics()) {
        this.#live.stop(topic);
        this.#shown.set(keyOf(topic), Compute.#empty());
        kernel.store.invalidate(topic);
        this.#live.run(topic, this.#keep(topic));
      }
    });

    kernel.calls({
      "compute.refresh": {
        run: () =>
          Effect.sync(() => {
            for (const topic of this.#topics()) {
              const shown = this.#shown.get(keyOf(topic));
              if (shown) shown.reads = 0;
              this.#live.stop(topic);
              this.#live.run(topic, this.#keep(topic));
            }
            return null;
          }),
      },
      "compute.observe": {
        // The local node ticked: one read when something is preparing (or nothing was read yet).
        run: () =>
          Effect.forEach(this.#topics(), (topic) => {
            const shown = this.#shown.get(keyOf(topic));
            return shown && this.#wanted(shown) ? this.#read(topic) : Effect.void;
          }).pipe(Effect.as(null)),
      },
      "compute.create": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const environment = params.string(p, "environment");
          const raw = (p as { name?: unknown }).name;
          const name = typeof raw === "string" ? raw.trim().slice(0, 80) : "";
          return this.#create(workspace, environment, name);
        },
      },
      "compute.workload": {
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const id = params.string(p, "id");
          return this.#send("GET", workloadPath(workspace, id)).pipe(
            Effect.map((answer) => answer.workload)
          );
        },
      },
      "compute.retry": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const id = params.string(p, "id");
          const generation = params.int(p, "generation");
          return this.#change(
            workspace,
            "POST",
            `${workloadPath(workspace, id)}/retry`,
            { generation }
          );
        },
      },
      "compute.rename": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const id = params.string(p, "id");
          const name = params.string(p, "name", 80).trim();
          // The last rename wins: the server compares no revision.
          return this.#change(workspace, "PATCH", workloadPath(workspace, id), {
            name,
          });
        },
      },
      "compute.delete": {
        doing: true,
        run: (p) => {
          const workspace = params.string(p, "workspace");
          const id = params.string(p, "id");
          const generation = params.int(p, "generation");
          const given = (p as { request?: unknown }).request;
          return Effect.suspend(() => {
            const account = this.#ctx.session.current();
            if (!account)
              return Effect.fail(new CoreError("signed_out", "No one is signed in."));
            // The same request id until the server answers: a deletion asked twice happens once.
            const requestId =
              (typeof given === "string" && given) ||
              account.meta<string>(deletionKey(workspace, id)) ||
              this.#requestId();
            account.setMeta(deletionKey(workspace, id), requestId);
            return this.#change(
              workspace,
              "POST",
              `${workloadPath(workspace, id)}/deletion`,
              { generation, request_id: requestId }
            );
          });
        },
      },
    });
  }

  static #empty(): Shown {
    return {
      workspace: null,
      projection: null,
      error: false,
      creation: null,
      accepted: null,
      reads: 0,
      lock: Semaphore.makeUnsafe(1),
    };
  }

  #topics(): Topic[] {
    return this.#ctx.kernel.store.liveTopics().filter((t) => t.topic === "compute");
  }

  #requestId(): string {
    const bytes = new Uint8Array(16);
    this.#ctx.host.randomBytes(bytes);
    bytes[6] = (bytes[6]! & 0x0f) | 0x40;
    bytes[8] = (bytes[8]! & 0x3f) | 0x80;
    const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  #send(method: "GET" | "POST" | "PATCH", path: string, body?: unknown) {
    const ctx = this.#ctx;
    return ctx.session
      .account()
      .pipe(
        Effect.flatMap((account) =>
          ctx.api.request(account, method, path, answerSchema, body)
        )
      );
  }

  #changed(topic: Topic): void {
    this.#ctx.kernel.store.invalidate(topic);
  }

  /** Whether a read is wanted: nothing read yet, something preparing, or a creation awaiting its answer. */
  #wanted(shown: Shown): boolean {
    return (
      shown.reads < this.#ctx.limits.computeReadsPerVisit &&
      (!shown.projection ||
        shown.creation !== null ||
        shown.projection.workloads.some(preparing) ||
        (shown.accepted !== null && preparing(shown.accepted)))
    );
  }

  /** The first read, then (unless the page drives them) every 5 s while something prepares, up to `limits.computeReadsPerVisit` reads (60). */
  #keep(topic: Topic): Effect.Effect<void> {
    return Effect.gen({ self: this }, function* () {
      // The first read always happens (the page opened, a person refreshed or changed something).
      let first = true;
      for (;;) {
        const shown = this.#shown.get(keyOf(topic));
        if (
          !shown ||
          (!first && !this.#wanted(shown)) ||
          shown.reads >= this.#ctx.limits.computeReadsPerVisit
        )
          return;
        first = false;
        yield* this.#read(topic);
        if (topic.shared === "1") return;
        const after = this.#shown.get(keyOf(topic));
        if (!after || (!this.#wanted(after) && !after.error)) return;
        if (after.reads >= this.#ctx.limits.computeReadsPerVisit) return;
        yield* Effect.sleep(EVERY_MS);
      }
    });
  }

  #workspaceOf(account: Account, prefer: string): string | null {
    const list = this.#workspaces.list(account) ?? [];
    return (list.find((w) => w.id === prefer) ?? list[0])?.id ?? null;
  }

  /** One read: the page, then a creation awaiting its answer (kept on the device) by its request id. */
  #read(topic: Topic): Effect.Effect<void> {
    const key = keyOf(topic);
    const shown = this.#shown.get(key);
    if (!shown) return Effect.void;
    return shown.lock.withPermits(1)(
      Effect.gen({ self: this }, function* () {
        const ctx = this.#ctx;
        const account = yield* ctx.session.account().pipe(Effect.option);
        if (Option.isNone(account) || this.#shown.get(key) !== shown) return;
        if (!this.#workspaceOf(account.value, String(topic.prefer ?? "")))
          yield* this.#workspaces.refresh().pipe(Effect.ignore);
        const workspace = this.#workspaceOf(account.value, String(topic.prefer ?? ""));
        shown.reads += 1;
        if (!workspace) {
          shown.error = true;
          this.#changed(topic);
          return;
        }
        shown.workspace = workspace;
        const query = new URLSearchParams({
          workload_after: String(topic.after ?? ""),
        });
        const projection = yield* ctx.api
          .request(
            account.value,
            "GET",
            `${base(workspace)}?${query}`,
            computeProjectionSchema
          )
          .pipe(Effect.option);
        if (Option.isNone(projection)) {
          shown.error = true;
          this.#changed(topic);
          return;
        }
        shown.projection = projection.value;
        shown.error = false;
        const saved = account.value.meta<Creation>(creationKey(workspace));
        shown.creation = saved ?? null;
        if (saved) {
          const answer = yield* ctx.api
            .request(
              account.value,
              "GET",
              `${base(workspace)}/requests/${encodeURIComponent(saved.requestId)}`,
              answerSchema
            )
            .pipe(Effect.result);
          if (Result.isSuccess(answer)) {
            if (
              account.value.meta<Creation>(creationKey(workspace))?.requestId !==
              saved.requestId
            )
              return;
            account.value.setMeta(creationKey(workspace), null);
            shown.creation = null;
            shown.accepted = currentWorkload(answer.success.workload)
              ? answer.success.workload
              : null;
          } else if (answer.failure.status !== 404) {
            // A not-found read can race the original commit: keep the same id and ask again.
            shown.error = true;
          }
        }
        if (!saved && shown.accepted) {
          const listed = projection.value.workloads.find(
            (w) => w.id === shown.accepted?.id
          );
          if (listed) shown.accepted = null;
          else {
            // The recovered workload may be outside the current list page.
            const current = yield* ctx.api
              .request(
                account.value,
                "GET",
                workloadPath(workspace, shown.accepted.id),
                answerSchema
              )
              .pipe(Effect.option);
            if (Option.isSome(current))
              shown.accepted = currentWorkload(current.value.workload)
                ? current.value.workload
                : null;
            else shown.error = true;
          }
        }
        this.#changed(topic);
      })
    );
  }

  /** Creates a Shell: its request id is kept on the device before it is sent, and reused until answered. */
  #create(
    workspace: string,
    environment: string,
    name: string
  ): Effect.Effect<ComputeWorkload, CoreError> {
    return Effect.suspend(() => {
      const account = this.#ctx.session.current();
      if (!account)
        return Effect.fail(new CoreError("signed_out", "No one is signed in."));
      const target: Creation = account.meta<Creation>(creationKey(workspace)) ?? {
        requestId: this.#requestId(),
        environmentId: environment,
        ...(name ? { name } : {}),
      };
      account.setMeta(creationKey(workspace), target);
      this.#each(workspace, (shown) => {
        shown.creation = target;
        shown.reads = 0;
      });
      this.#restart(workspace);
      return this.#send("POST", `${base(workspace)}/workloads`, {
        environment_id: target.environmentId,
        kind: "shell",
        request_id: target.requestId,
        ...(target.name ? { name: target.name } : {}),
      }).pipe(
        Effect.tap((answer) =>
          Effect.sync(() => {
            // A recovery or a newer creation already replaced this request.
            if (
              account.meta<Creation>(creationKey(workspace))?.requestId !==
              target.requestId
            )
              return;
            account.setMeta(creationKey(workspace), null);
            this.#each(workspace, (shown) => {
              shown.creation = null;
              shown.accepted = currentWorkload(answer.workload)
                ? answer.workload
                : null;
              shown.reads = 0;
            });
            this.#restart(workspace);
          })
        ),
        Effect.map((answer) => answer.workload)
      );
    });
  }

  /** A change to a workload: its answer is the caller's; the page is read again. */
  #change(
    workspace: string,
    method: "POST" | "PATCH",
    path: string,
    body: unknown
  ): Effect.Effect<ComputeWorkload, CoreError> {
    return this.#send(method, path, body).pipe(
      Effect.tap((answer) =>
        Effect.sync(() => {
          this.#each(workspace, (shown) => {
            shown.reads = 0;
            if (shown.accepted?.id === answer.workload.id)
              shown.accepted = currentWorkload(answer.workload)
                ? answer.workload
                : null;
          });
          this.#restart(workspace);
        })
      ),
      Effect.map((answer) => answer.workload)
    );
  }

  #each(workspace: string, change: (shown: Shown) => void): void {
    for (const topic of this.#topics()) {
      const shown = this.#shown.get(keyOf(topic));
      if (!shown || (shown.workspace && shown.workspace !== workspace)) continue;
      change(shown);
      this.#changed(topic);
    }
  }

  #restart(workspace: string): void {
    for (const topic of this.#topics()) {
      const shown = this.#shown.get(keyOf(topic));
      if (!shown || (shown.workspace && shown.workspace !== workspace)) continue;
      this.#live.stop(topic);
      this.#live.run(topic, this.#keep(topic));
    }
  }
}

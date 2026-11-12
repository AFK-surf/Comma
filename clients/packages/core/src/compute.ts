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
import { lazySchema } from "@comma/chat-contract";
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
const answerSchema = lazySchema(() => z.object({ workload: computeWorkloadSchema }));

type Deletion = NonNullable<ComputeValue["deletion"]>;
type SavedDeletion = Deletion & { terminal?: { phase: string; proof?: unknown } };
// These owner transaction refusals commit no deletion. HTTP status alone says nothing about acceptance.
const deletionRefusal = (error: CoreError) =>
  [
    "invalid_deletion_request",
    "revision_conflict",
    "stale_generation",
    "deletion_in_progress",
    "business_owner_required",
    "update_in_progress",
    "unsupported_provider",
    "shared_allocation",
  ].includes(error.code);
const deletionIndex = (ws: string) => `computeDeletion:${ws}`;

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
      evictAfterMs: 0,
      start: (topic) => {
        this.#shown.set(keyOf(topic), Compute.#empty());
        this.#live.run(topic, this.#keep(topic));
      },
      stop: (topic) => {
        this.#live.stop(topic);
        this.#shown.delete(keyOf(topic));
      },
      compute: (topic): Value => {
        const shown = this.#shown.get(keyOf(topic)) ?? Compute.#empty();
        const { reads: _r, lock: _l, ...value } = shown;
        return {
          ok: {
            ...value,
            observationPaused:
              shown.reads >= ctx.limits.computeReadsPerVisit &&
              this.#needsObservation(shown),
          },
        };
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
            return shown && this.#wanted(shown) ? this.#read(topic, true) : Effect.void;
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
          return Effect.gen({ self: this }, function* () {
            const account = yield* this.#ctx.session.account();
            const read = yield* this.#send("GET", workloadPath(workspace, id)).pipe(
              Effect.result
            );
            if (Result.isFailure(read)) {
              const saved = account.meta<SavedDeletion | string>(
                deletionKey(workspace, id)
              );
              if (
                saved &&
                (read.failure.status === 403 || read.failure.status === 404)
              ) {
                const target: Deletion =
                  typeof saved === "string"
                    ? { workloadId: id, requestId: saved, uncertain: true }
                    : saved;
                const queryOnly = { ...target, canContinue: false };
                account.setMeta(deletionKey(workspace, id), queryOnly);
                if (this.#ctx.session.current() === account)
                  this.#each(workspace, (shown) => {
                    if (shown.deletion?.requestId === target.requestId)
                      shown.deletion = queryOnly;
                  });
              }
              return yield* Effect.fail(read.failure);
            }
            const answer = read.success;
            if (account.meta<Deletion | string>(deletionKey(workspace, id))) {
              account.setMeta(deletionIndex(workspace), id);
              const target = this.#savedDeletion(account, workspace);
              if (target) {
                this.#each(workspace, (shown) => {
                  shown.deletion = target;
                });
                this.#observeDeletion(
                  account,
                  workspace,
                  target,
                  answer.workload,
                  true
                );
              }
            }
            return answer.workload;
          });
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
          return this.#delete(
            workspace,
            id,
            generation,
            typeof given === "string" ? given : undefined,
            (p as { confirmLegacy?: unknown }).confirmLegacy === true
          );
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
      creationReadError: false,
      deletion: null,
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
      this.#needsObservation(shown)
    );
  }

  #needsObservation(shown: Shown): boolean {
    return (
      !shown.projection ||
      shown.creation !== null ||
      !!shown.deletion?.uncertain ||
      (!!shown.deletion?.workload && preparing(shown.deletion.workload)) ||
      shown.projection.workloads.some(
        (workload) =>
          preparing(workload) &&
          !(
            shown.deletion?.terminal &&
            workload.id === shown.deletion.workloadId &&
            workload.generation === shown.deletion.generation
          )
      ) ||
      (shown.accepted !== null && preparing(shown.accepted))
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
  #read(topic: Topic, background = false): Effect.Effect<void> {
    const key = keyOf(topic);
    const shown = this.#shown.get(key);
    if (!shown) return Effect.void;
    const withPermit = background
      ? (read: Effect.Effect<void>) =>
          shown.lock.withPermitsIfAvailable(1)(read).pipe(Effect.asVoid)
      : (read: Effect.Effect<void>) => shown.lock.withPermits(1)(read);
    return withPermit(
      Effect.gen({ self: this }, function* () {
        const ctx = this.#ctx;
        const account = yield* ctx.session.account().pipe(Effect.option);
        if (
          Option.isNone(account) ||
          this.#shown.get(key) !== shown ||
          shown.reads >= ctx.limits.computeReadsPerVisit
        )
          return;
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
        if (this.#shown.get(key) !== shown || ctx.session.current() !== account.value)
          return;
        if (Option.isNone(projection)) {
          shown.error = true;
          this.#changed(topic);
          return;
        }
        shown.projection = projection.value;
        shown.error = false;
        shown.creationReadError = false;
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
          if (this.#shown.get(key) !== shown || ctx.session.current() !== account.value)
            return;
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
            shown.creationReadError = true;
          }
        }
        const deletion = this.#savedDeletion(account.value, workspace);
        shown.deletion = deletion;
        if (deletion) {
          const listed = projection.value.workloads.find(
            (w) => w.id === deletion.workloadId
          );
          if (listed) this.#observeDeletion(account.value, workspace, deletion, listed);
          else if (
            !saved &&
            (deletion.uncertain || (deletion.workload && preparing(deletion.workload)))
          ) {
            // One exact target, never a scan of saved requests or all workloads.
            const answer = yield* ctx.api
              .request(
                account.value,
                "GET",
                workloadPath(workspace, deletion.workloadId),
                answerSchema
              )
              .pipe(Effect.option);
            if (
              this.#shown.get(key) !== shown ||
              ctx.session.current() !== account.value
            )
              return;
            if (Option.isSome(answer))
              this.#observeDeletion(
                account.value,
                workspace,
                deletion,
                answer.value.workload,
                true
              );
          }
          shown.deletion = this.#savedDeletion(account.value, workspace);
        }
        if (
          !saved &&
          !(
            deletion?.uncertain ||
            (deletion?.workload && preparing(deletion.workload))
          ) &&
          shown.accepted
        ) {
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
            if (
              this.#shown.get(key) !== shown ||
              ctx.session.current() !== account.value
            )
              return;
            if (Option.isSome(current))
              shown.accepted = currentWorkload(current.value.workload)
                ? current.value.workload
                : null;
            else shown.creationReadError = true;
          }
        }
        this.#changed(topic);
      })
    );
  }

  #savedDeletion(account: Account, workspace: string): Deletion | null {
    const id = account.meta<string>(deletionIndex(workspace));
    if (!id) return null;
    const value = account.meta<SavedDeletion | string>(deletionKey(workspace, id));
    if (typeof value === "string")
      return { workloadId: id, requestId: value, uncertain: true, canContinue: false };
    if (!value?.terminal) return value;
    // A terminal receipt needs no persisted workload payload. Keep the current view's facts only in memory.
    const visible = [...this.#shown.values()].find(
      (shown) =>
        shown.workspace === workspace && shown.deletion?.requestId === value.requestId
    )?.deletion;
    return { ...value, ...(visible?.workload ? { workload: visible.workload } : {}) };
  }

  #observeDeletion(
    account: Account,
    workspace: string,
    target: Deletion,
    workload: ComputeWorkload,
    exact = false
  ): void {
    if (workload.id !== target.workloadId) return;
    const current = account.meta<SavedDeletion | string>(
      deletionKey(workspace, target.workloadId)
    );
    if (
      (typeof current === "string" ? current : current?.requestId) !== target.requestId
    )
      return;
    if (
      typeof current !== "string" &&
      current?.terminal &&
      (workload.deletion?.request_id !== target.requestId ||
        currentWorkload(workload) ||
        workload.deletion?.phase !== current.terminal.phase)
    )
      return;
    if (typeof current !== "string" && current?.workload) {
      const previous = current.workload;
      if ((previous.revision ?? 0) > (workload.revision ?? 0)) return;
      // Acceptance cannot turn back into an unaccepted ready snapshot for the same request.
      if (
        previous.deletion?.request_id === target.requestId &&
        workload.deletion?.request_id !== target.requestId
      )
        return;
    }
    const receiptGeneration = workload.deletion?.generation;
    const matches =
      workload.deletion?.request_id === target.requestId &&
      (target.generation === undefined ||
        receiptGeneration === undefined ||
        receiptGeneration === target.generation);
    const observed: Deletion = {
      ...target,
      // A legacy request can only gain a generation from its exact owner receipt.
      ...(target.generation === undefined &&
      matches &&
      typeof receiptGeneration === "number" &&
      Number.isInteger(receiptGeneration) &&
      receiptGeneration > 0
        ? { generation: receiptGeneration }
        : {}),
      uncertain: matches ? false : target.uncertain,
      canContinue:
        !matches &&
        (exact || target.canContinue !== false) &&
        target.generation !== undefined &&
        workload.generation === target.generation &&
        !workload.deletion &&
        currentWorkload(workload),
      // Once accepted, retain only its receipt and display identity, not the complete detail payload.
      workload: matches
        ? {
            id: workload.id,
            environment_id: workload.environment_id,
            kind: workload.kind,
            name: workload.name,
            generation: workload.generation,
            revision: workload.revision,
            desired_state: workload.desired_state,
            observed_state: workload.observed_state,
            phase: workload.phase,
            location: workload.location,
            deletion: workload.deletion
              ? {
                  request_id: workload.deletion.request_id,
                  phase: workload.deletion.phase,
                  generation: workload.deletion.generation,
                  proof: workload.deletion.proof,
                  error: workload.deletion.error,
                }
              : null,
          }
        : workload,
    };
    account.setMeta(
      deletionKey(workspace, target.workloadId),
      matches && !currentWorkload(workload)
        ? {
            workloadId: observed.workloadId,
            requestId: observed.requestId,
            generation: observed.generation,
            uncertain: false,
            canContinue: false,
            terminal: {
              phase: workload.deletion?.phase ?? workload.phase,
              proof: workload.deletion?.proof,
            },
          }
        : observed
    );
    if (this.#ctx.session.current() === account)
      this.#each(workspace, (shown) => {
        if (shown.deletion?.requestId === target.requestId) shown.deletion = observed;
        if (matches && !currentWorkload(workload) && shown.accepted?.id === workload.id)
          shown.accepted = null;
      });
  }

  #delete(
    workspace: string,
    id: string,
    generation: number,
    given?: string,
    confirmLegacy = false
  ): Effect.Effect<ComputeWorkload, CoreError> {
    return Effect.gen({ self: this }, function* () {
      const account = yield* this.#ctx.session.account();
      const saved = account.meta<SavedDeletion | string>(deletionKey(workspace, id));
      const target: Deletion =
        typeof saved === "string"
          ? { workloadId: id, requestId: saved, uncertain: true }
          : (saved ?? {
              workloadId: id,
              requestId: given || this.#requestId(),
              generation,
              uncertain: true,
              canContinue: true,
              workload: [...this.#shown.values()]
                .filter((shown) => shown.workspace === workspace)
                .flatMap((shown) => [
                  ...(shown.projection?.workloads ?? []),
                  ...(shown.accepted ? [shown.accepted] : []),
                ])
                .find((workload) => workload.id === id),
            });
      account.setMeta(deletionKey(workspace, id), target);
      account.setMeta(deletionIndex(workspace), id);
      this.#each(workspace, (shown) => {
        shown.deletion = target;
        shown.reads = 0;
      });
      if (saved) {
        const read = yield* this.#send("GET", workloadPath(workspace, id)).pipe(
          Effect.result
        );
        if (Result.isSuccess(read)) {
          this.#observeDeletion(
            account,
            workspace,
            target,
            read.success.workload,
            true
          );
          if (
            read.success.workload.id === id &&
            read.success.workload.deletion?.request_id === target.requestId
          ) {
            this.#restart(workspace);
            return read.success.workload;
          }
        }
        // A legacy request needs a fresh confirmation of the displayed target and a positive owner read.
        // Keep its generation unknown until an owner receipt binds the original request.
        const freshLegacyConfirmation =
          target.generation === undefined &&
          confirmLegacy &&
          Result.isSuccess(read) &&
          read.success.workload.generation === generation &&
          read.success.workload.actions?.delete === true;
        if (
          Result.isFailure(read) ||
          !target.uncertain ||
          read.success.workload.id !== id ||
          (target.generation === undefined
            ? !freshLegacyConfirmation
            : target.generation !== generation ||
              read.success.workload.generation !== target.generation) ||
          read.success.workload.deletion ||
          !currentWorkload(read.success.workload)
        ) {
          const latest = account.meta<SavedDeletion | string>(
            deletionKey(workspace, id)
          );
          const queryOnly = {
            ...(typeof latest === "object" && latest ? latest : target),
            canContinue: false,
          };
          account.setMeta(deletionKey(workspace, id), queryOnly);
          if (this.#ctx.session.current() === account)
            this.#each(workspace, (shown) => {
              shown.deletion = queryOnly;
            });
          this.#restart(workspace);
          return yield* Effect.fail(
            new CoreError("deletion_uncertain", "Check the original deletion result.")
          );
        }
      }
      const answer = yield* this.#send(
        "POST",
        `${workloadPath(workspace, id)}/deletion`,
        {
          generation: target.generation ?? generation,
          request_id: target.requestId,
        }
      ).pipe(Effect.result);
      if (Result.isSuccess(answer)) {
        this.#observeDeletion(account, workspace, target, answer.success.workload);
        if (this.#ctx.session.current() === account)
          this.#each(workspace, (shown) => {
            shown.reads = 0;
            if (shown.accepted?.id === id)
              shown.accepted = currentWorkload(answer.success.workload)
                ? answer.success.workload
                : null;
          });
        this.#restart(workspace);
        return answer.success.workload;
      }
      if (!saved && deletionRefusal(answer.failure)) {
        account.setMeta(deletionKey(workspace, id), null);
        if (this.#ctx.session.current() === account)
          this.#each(workspace, (shown) => {
            if (shown.deletion?.requestId === target.requestId) shown.deletion = null;
          });
      }
      this.#restart(workspace);
      return yield* Effect.fail(
        saved && target.uncertain
          ? new CoreError(
              "deletion_uncertain",
              "Check the original deletion result.",
              answer.failure.status
            )
          : answer.failure
      );
    });
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
      Effect.tapError(() =>
        Effect.sync(() => {
          // A transport or post-commit read failure still invalidates the existing bounded page observation.
          this.#each(workspace, (shown) => {
            shown.reads = 0;
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

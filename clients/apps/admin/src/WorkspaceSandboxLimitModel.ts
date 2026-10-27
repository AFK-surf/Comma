// The Workspace's own coding sandbox limit, which overrides the deployment default for its
// coding sandboxes that run at the same time (docs/compute-devices.md#coding-sandboxes). Salix
// owns the setting; the change is an audited Admin command.
import { Effect, FiberHandle, SubscriptionRef } from "effect";
import {
  AdminApi,
  createIdempotencyKey,
  type AdminWorkspaceSandboxLimit,
} from "./adminApi";
import { makeConfirmation, makeFailures, type Confirmation } from "./adminModel";
import { messages } from "@comma/i18n";

/** The most a Workspace may set, as the server accepts. */
export const MAX_SANDBOX_LIMIT = 100;

export interface WorkspaceSandboxLimitState {
  readonly editing: boolean;
  readonly loadError: string | undefined;
  readonly notice: string | undefined;
  /** The edited limit; empty uses the deployment default. */
  readonly limit: string;
  /** The saved setting; undefined until it loads. */
  readonly view: AdminWorkspaceSandboxLimit | undefined;
}

export interface WorkspaceSandboxLimitModel {
  readonly state: SubscriptionRef.SubscriptionRef<WorkspaceSandboxLimitState>;
  readonly confirmation: Confirmation;
  readonly edit: Effect.Effect<void>;
  readonly setLimit: (limit: string) => Effect.Effect<void>;
  /** Leaves editing and puts the saved limit back. */
  readonly cancelEdit: Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  readonly review: Effect.Effect<void>;
}

/** The edited limit as the form reads it: null is the deployment default. */
export function workspaceSandboxLimitForm(
  state: WorkspaceSandboxLimitState,
  busy: boolean
) {
  const value = state.limit.trim();
  const parsed = value === "" ? null : /^\d+$/.test(value) ? Number(value) : Number.NaN;
  const valid = parsed === null || (parsed >= 1 && parsed <= MAX_SANDBOX_LIMIT);
  const saved = state.view?.override ?? null;
  return {
    canReview: !busy && valid && parsed !== saved,
    limit: valid ? parsed : undefined,
    saved,
    valid,
  };
}

const savedText = (view: AdminWorkspaceSandboxLimit | undefined) =>
  view?.override == null ? "" : String(view.override);

const shown = (value: number | null | undefined) =>
  value == null ? messages.admin_sandbox_limit_default() : String(value);

export const makeWorkspaceSandboxLimitModel = (userId: string) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const failures = yield* makeFailures;
    const confirmation = yield* makeConfirmation;
    const loading = yield* FiberHandle.make();
    const state = yield* SubscriptionRef.make<WorkspaceSandboxLimitState>({
      editing: false,
      limit: "",
      loadError: undefined,
      notice: undefined,
      view: undefined,
    });
    const update = (
      change: (current: WorkspaceSandboxLimitState) => WorkspaceSandboxLimitState
    ) => SubscriptionRef.update(state, change);
    // One key per edited command: a retry of the same command repeats it, an edit makes a new one.
    let idempotencyKey = yield* Effect.sync(() =>
      createIdempotencyKey("workspace-sandbox-limit")
    );
    const newKey = Effect.sync(() => {
      idempotencyKey = createIdempotencyKey("workspace-sandbox-limit");
    });

    yield* FiberHandle.run(
      loading,
      api.getUserWorkspaceSandboxLimit(userId).pipe(
        Effect.matchEffect({
          onFailure: (error) =>
            failures
              .read(error, messages.admin_sandbox_limit_load_error())
              .pipe(
                Effect.flatMap((message) =>
                  message
                    ? update((current) => ({ ...current, loadError: message }))
                    : Effect.void
                )
              ),
          onSuccess: (loaded) =>
            update((current) => ({
              ...current,
              limit: savedText(loaded),
              view: loaded,
            })),
        })
      )
    );

    const save =
      (limit: number | null, expected: string) => (key: string, reason: string) =>
        Effect.gen(function* () {
          const updated = yield* api.updateUserWorkspaceSandboxLimit(userId, {
            maxSandboxes: limit,
            reason,
            confirmation: expected,
            idempotencyKey: key,
          });
          yield* newKey;
          yield* update((current) => ({
            ...current,
            editing: false,
            limit: savedText(updated),
            notice:
              updated.override == null
                ? messages.admin_sandbox_limit_default_set()
                : messages.admin_sandbox_limit_set({ limit: String(updated.override) }),
            view: updated,
          }));
        }).pipe(Effect.catch((error) => Effect.flip(failures.command(error))));

    const model: WorkspaceSandboxLimitModel = {
      state,
      confirmation,
      edit: update((current) => ({ ...current, editing: true })),
      setLimit: (limit) =>
        update((current) => ({ ...current, limit })).pipe(Effect.andThen(newKey)),
      cancelEdit: update((current) => ({
        ...current,
        editing: false,
        limit: savedText(current.view),
      })),
      dismissNotice: update((current) => ({ ...current, notice: undefined })),
      review: Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        const busy = (yield* SubscriptionRef.get(confirmation.state))?.busy ?? false;
        const { canReview, limit } = workspaceSandboxLimitForm(current, busy);
        if (!current.view || !current.editing || !canReview || limit === undefined)
          return;
        const expected = `workspace-sandbox-limit:${userId}:${limit ?? "default"}`;
        yield* confirmation.open({
          changes: [
            {
              label: messages.admin_sandbox_limit(),
              before: shown(current.view.override),
              after: shown(limit),
            },
          ],
          key: idempotencyKey,
          keyPrefix: "workspace-sandbox-limit",
          run: save(limit, expected),
          title:
            limit === null
              ? messages.admin_sandbox_limit_default_title()
              : messages.admin_sandbox_limit_set_title(),
        });
      }),
    };
    return model;
  });

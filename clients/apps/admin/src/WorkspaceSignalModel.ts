// The Workspace's own Signal number, which overrides the platform number for new Signal connections
// (docs/messaging-voice.md). Salix owns the setting; the change is an audited Admin command.
import { Effect, FiberHandle, SubscriptionRef } from "effect";
import {
  AdminApi,
  createIdempotencyKey,
  type AdminWorkspaceSignalNumber,
} from "./adminApi";
import { makeConfirmation, makeFailures, type Confirmation } from "./adminModel";
import { messages } from "@comma/i18n";

const E164 = /^\+[1-9]\d{6,14}$/;

export interface WorkspaceSignalState {
  readonly editing: boolean;
  readonly loadError: string | undefined;
  readonly notice: string | undefined;
  /** The edited number, without spaces, brackets or dashes. */
  readonly number: string;
  /** The saved setting; undefined until it loads. */
  readonly view: AdminWorkspaceSignalNumber | undefined;
}

export interface WorkspaceSignalModel {
  readonly state: SubscriptionRef.SubscriptionRef<WorkspaceSignalState>;
  readonly confirmation: Confirmation;
  readonly edit: Effect.Effect<void>;
  readonly setNumber: (number: string) => Effect.Effect<void>;
  /** Leaves editing and puts the saved number back. */
  readonly cancelEdit: Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  readonly review: Effect.Effect<void>;
}

/** The edited number as the form reads it. */
export function workspaceSignalForm(state: WorkspaceSignalState, busy: boolean) {
  const value = state.number.trim();
  const saved = state.view?.override?.e164 ?? "";
  const valid = value === "" || E164.test(value);
  return {
    canReview: !busy && valid && value !== saved,
    saved,
    valid,
    value,
  };
}

export const makeWorkspaceSignalModel = (userId: string) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const failures = yield* makeFailures;
    const confirmation = yield* makeConfirmation;
    const loading = yield* FiberHandle.make();
    const state = yield* SubscriptionRef.make<WorkspaceSignalState>({
      editing: false,
      loadError: undefined,
      notice: undefined,
      number: "",
      view: undefined,
    });
    const update = (change: (current: WorkspaceSignalState) => WorkspaceSignalState) =>
      SubscriptionRef.update(state, change);
    // One key per edited command: a retry of the same command repeats it, an edit makes a new one.
    let idempotencyKey = yield* Effect.sync(() =>
      createIdempotencyKey("workspace-signal-number")
    );
    const newKey = Effect.sync(() => {
      idempotencyKey = createIdempotencyKey("workspace-signal-number");
    });

    yield* FiberHandle.run(
      loading,
      api.getUserWorkspaceSignalNumber(userId).pipe(
        Effect.matchEffect({
          onFailure: (error) =>
            failures
              .read(error, messages.admin_signal_load_error())
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
              number: loaded.override?.e164 ?? "",
              view: loaded,
            })),
        })
      )
    );

    const save = (value: string, expected: string) => (key: string, reason: string) =>
      Effect.gen(function* () {
        const updated = yield* api.updateUserWorkspaceSignalNumber(userId, {
          number: value,
          reason,
          confirmation: expected,
          idempotencyKey: key,
        });
        yield* newKey;
        yield* update((current) => ({
          ...current,
          editing: false,
          notice: updated.override?.e164
            ? messages.admin_signal_set({ number: updated.override.e164 })
            : messages.admin_signal_platform(),
          number: updated.override?.e164 ?? "",
          view: updated,
        }));
      }).pipe(Effect.catch((error) => Effect.flip(failures.command(error))));

    const model: WorkspaceSignalModel = {
      state,
      confirmation,
      edit: update((current) => ({ ...current, editing: true })),
      setNumber: (number) =>
        update((current) => ({
          ...current,
          number: number.replace(/[\s()-]/g, ""),
        })).pipe(Effect.andThen(newKey)),
      cancelEdit: update((current) => ({
        ...current,
        editing: false,
        number: current.view?.override?.e164 ?? "",
      })),
      dismissNotice: update((current) => ({ ...current, notice: undefined })),
      review: Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        const busy = (yield* SubscriptionRef.get(confirmation.state))?.busy ?? false;
        const { canReview, value } = workspaceSignalForm(current, busy);
        if (!current.view || !current.editing || !canReview) return;
        const expected = `workspace-signal-number:${userId}:${value}`;
        yield* confirmation.open({
          changes: [
            {
              label: messages.admin_signal_number(),
              before: current.view.override?.e164 || messages.admin_platform_number(),
              after: value || messages.admin_platform_number(),
            },
          ],
          key: idempotencyKey,
          keyPrefix: "workspace-signal-number",
          run: save(value, expected),
          title: value
            ? messages.admin_signal_set_title()
            : messages.admin_signal_platform_title(),
        });
      }),
    };
    return model;
  });

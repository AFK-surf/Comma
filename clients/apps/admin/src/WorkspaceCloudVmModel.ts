// The desired Cloud VM setting of a User's default Workspace, changed by an audited Admin command.
import { Effect, SubscriptionRef } from "effect";
import { AdminApi, createIdempotencyKey, type AdminWorkspaceVm } from "./adminApi";
import { makeConfirmation, makeFailures, type Confirmation } from "./adminModel";
import { messages } from "@comma/i18n";

export interface WorkspaceCloudVmState {
  readonly notice: string | undefined;
  /** The setting the server last returned. */
  readonly saved: AdminWorkspaceVm;
}

export interface WorkspaceCloudVmModel {
  readonly state: SubscriptionRef.SubscriptionRef<WorkspaceCloudVmState>;
  readonly confirmation: Confirmation;
  /** Whether the Workspace is ready; only a ready Workspace can be changed. */
  readonly ready: boolean;
  readonly dismissNotice: Effect.Effect<void>;
  /** Reviews setting Cloud VM to `enabled`; the same setting again retries a failed configuration. */
  readonly review: (enabled: boolean) => Effect.Effect<void>;
}

/** Whether the saved setting failed to apply, so the same setting can be sent again. */
export const workspaceCloudVmFailed = (state: WorkspaceCloudVmState) =>
  state.saved.convergence_status === "terminal_failed";

export const makeWorkspaceCloudVmModel = (options: {
  readonly current: AdminWorkspaceVm;
  readonly ready: boolean;
  readonly userId: string;
}) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const failures = yield* makeFailures;
    const confirmation = yield* makeConfirmation;
    const { current, userId } = options;
    const state = yield* SubscriptionRef.make<WorkspaceCloudVmState>({
      notice: undefined,
      saved: current,
    });
    // One key per command: a retry of the same setting repeats it, another setting makes a new one.
    let command: { readonly enabled: boolean; readonly key: string } | undefined;
    const keyFor = (enabled: boolean) =>
      Effect.sync(() => {
        if (command?.enabled !== enabled) {
          command = { enabled, key: createIdempotencyKey("workspace-vm") };
        }
        return command.key;
      });

    const save =
      (enabled: boolean, expected: string) => (key: string, reason: string) =>
        Effect.gen(function* () {
          const updated = yield* api.updateUserWorkspaceVm(
            userId,
            current.workspace_id,
            {
              enabled,
              reason,
              confirmation: expected,
              idempotencyKey: key,
            }
          );
          command = undefined;
          yield* SubscriptionRef.update(state, (value) => ({
            ...value,
            notice: messages.admin_vm_saved(),
            saved: updated,
          }));
        }).pipe(Effect.catch((error) => Effect.flip(failures.command(error))));

    const model: WorkspaceCloudVmModel = {
      state,
      confirmation,
      ready: options.ready,
      dismissNotice: SubscriptionRef.update(state, (value) => ({
        ...value,
        notice: undefined,
      })),
      review: (enabled) =>
        Effect.gen(function* () {
          const value = yield* SubscriptionRef.get(state);
          const busy = (yield* SubscriptionRef.get(confirmation.state))?.busy ?? false;
          if (!options.ready || busy) return;
          if (enabled === value.saved.enabled && !workspaceCloudVmFailed(value)) return;
          const expected = `workspace-vm:${current.workspace_id}:${enabled ? "enable" : "disable"}`;
          yield* confirmation.open({
            ...(enabled
              ? {}
              : {
                  explanation: messages.admin_vm_disable_explanation(),
                }),
            key: yield* keyFor(enabled),
            keyPrefix: "workspace-vm",
            run: save(enabled, expected),
            title: enabled
              ? messages.admin_vm_enable_title()
              : messages.admin_vm_disable_title(),
          });
        }),
    };
    return model;
  });

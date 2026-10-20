// Free Router models: the provider/SKU list whose Router main-model calls are not charged.
import { Effect, FiberHandle, SubscriptionRef } from "effect";
import { AdminApi, type FreeRouterPolicy } from "./adminApi";
import { makeConfirmation, makeFailures, type Confirmation } from "./adminModel";
import { messages } from "@comma/i18n";

export const updateFreeRouterModelsConfirmation = "update-free-router-models:comma";
const maxModels = 100;

export type FreeRouterModel = FreeRouterPolicy["models"][number];

export interface FreeRouterModelsState {
  readonly error: string | undefined;
  /** The edited list; saved only after review. */
  readonly models: ReadonlyArray<FreeRouterModel>;
  readonly notice: string | undefined;
  /** The saved policy; undefined while it loads. */
  readonly policy: FreeRouterPolicy | undefined;
  readonly provider: string;
  readonly sku: string;
}

export type FreeRouterModelsField = "provider" | "sku";

export interface FreeRouterModelsModel {
  readonly state: SubscriptionRef.SubscriptionRef<FreeRouterModelsState>;
  readonly confirmation: Confirmation;
  readonly reload: Effect.Effect<void>;
  readonly setField: (
    field: FreeRouterModelsField,
    value: string
  ) => Effect.Effect<void>;
  /** Adds the typed provider and SKU (lowercased) and clears them. */
  readonly addModel: Effect.Effect<void>;
  readonly removeModel: (index: number) => Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  readonly review: Effect.Effect<void>;
  /** Puts the list back to the saved policy. */
  readonly discard: Effect.Effect<void>;
}

/** Whether the edited list differs from the saved policy. */
export function freeRouterModelsChanged(state: FreeRouterModelsState) {
  return (
    state.policy !== undefined &&
    JSON.stringify(state.models) !== JSON.stringify(state.policy.models)
  );
}

const modelName = (entry: FreeRouterModel) => `${entry.provider}/${entry.sku}`;

/** The models the edited list adds and removes, against the saved policy. */
export function freeRouterModelChanges(state: FreeRouterModelsState) {
  const saved = new Set((state.policy?.models ?? []).map(modelName));
  const edited = new Set(state.models.map(modelName));
  return {
    added: [...edited].filter((name) => !saved.has(name)),
    removed: [...saved].filter((name) => !edited.has(name)),
  };
}

/** Whether the add form can add another model. */
export function canAddFreeRouterModel(state: FreeRouterModelsState) {
  return Boolean(
    state.provider.trim() && state.sku.trim() && state.models.length < maxModels
  );
}

export const makeFreeRouterModelsModel = Effect.gen(function* () {
  const api = yield* AdminApi;
  const failures = yield* makeFailures;
  const confirmation = yield* makeConfirmation;
  const state = yield* SubscriptionRef.make<FreeRouterModelsState>({
    error: undefined,
    models: [],
    notice: undefined,
    policy: undefined,
    provider: "",
    sku: "",
  });
  const loading = yield* FiberHandle.make();

  const update = (change: (current: FreeRouterModelsState) => FreeRouterModelsState) =>
    SubscriptionRef.update(state, change);

  const load = Effect.gen(function* () {
    yield* update((current) => ({ ...current, error: undefined, policy: undefined }));
    yield* api.getFreeRouterModels.pipe(
      Effect.matchEffect({
        onFailure: (error) =>
          failures
            .read(error, messages.admin_free_load_error())
            .pipe(
              Effect.flatMap((message) =>
                message
                  ? update((current) => ({ ...current, error: message }))
                  : Effect.void
              )
            ),
        onSuccess: (policy) =>
          update((current) => ({ ...current, models: policy.models, policy })),
      })
    );
  });
  const reload = FiberHandle.run(loading, load).pipe(Effect.asVoid);
  yield* reload;

  const save = (key: string, reason: string) =>
    Effect.gen(function* () {
      const { models, policy } = yield* SubscriptionRef.get(state);
      if (!policy) return;
      const saved = yield* api
        .updateFreeRouterModels(
          { revision: policy.revision, models },
          {
            confirmation: updateFreeRouterModelsConfirmation,
            idempotencyKey: key,
            reason,
          }
        )
        .pipe(
          Effect.catch((error) =>
            failures
              .command(error)
              .pipe(Effect.flatMap((message) => Effect.fail(message)))
          )
        );
      yield* update((current) => ({
        ...current,
        models: saved.models,
        notice: messages.admin_free_saved(),
        policy: saved,
      }));
    });

  const model: FreeRouterModelsModel = {
    state,
    confirmation,
    reload,
    setField: (field, value) => update((current) => ({ ...current, [field]: value })),
    addModel: update((current) => {
      const next = {
        provider: current.provider.trim().toLowerCase(),
        sku: current.sku.trim().toLowerCase(),
      };
      if (!next.provider || !next.sku || current.models.length >= maxModels)
        return current;
      const present = current.models.some(
        (entry) => entry.provider === next.provider && entry.sku === next.sku
      );
      return {
        ...current,
        models: present ? current.models : [...current.models, next],
        provider: "",
        sku: "",
      };
    }),
    removeModel: (index) =>
      update((current) => ({
        ...current,
        models: current.models.filter((_, position) => position !== index),
      })),
    dismissNotice: update((current) => ({ ...current, notice: undefined })),
    review: Effect.gen(function* () {
      const current = yield* SubscriptionRef.get(state);
      if (!freeRouterModelsChanged(current)) return;
      const { added, removed } = freeRouterModelChanges(current);
      yield* confirmation.open({
        changes: [
          ...added.map((name) => ({
            label: name,
            before: messages.admin_charged(),
            after: messages.admin_free(),
          })),
          ...removed.map((name) => ({
            label: name,
            before: messages.admin_free(),
            after: messages.admin_charged(),
          })),
        ],
        explanation: messages.admin_free_explanation(),
        keyPrefix: "free-router-models",
        run: save,
        title: messages.admin_free_save_title(),
        typed: "free models",
      });
    }),
    discard: update((current) =>
      current.policy
        ? { ...current, models: current.policy.models, provider: "", sku: "" }
        : current
    ),
  };
  return model;
});

// Redeem codes: the bounded code catalog and the create, apply and per-code drawers.
// Each drawer has its own model in a Scope that closes with the drawer, so its drafts and one-time plaintext go too.
import {
  DateTime,
  Effect,
  Exit,
  FiberHandle,
  Option,
  Result,
  Scope,
  SubscriptionRef,
} from "effect";
import {
  AdminApi,
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminLookupResult,
  type AdminPackageVersion,
  type AdminRedeemCodeCreation,
  type AdminRedeemTarget,
  type AdminRedemption,
  type AdminRedemptionResult,
} from "./adminApi";
import { AdminBrowser } from "./adminBrowser";
import {
  AdminShellLinks,
  makeConfirmation,
  makeFailures,
  type Confirmation,
  type Failures,
} from "./adminModel";
import {
  billingViewLimit,
  displayPrefix,
  packageVersionKey,
  selectedPackage,
  withoutRedeemCodePlaintext,
  type CatalogRedeemCode,
} from "./redeemCodeCatalog";
import { makeSearchModel, type SearchModel } from "./adminSearch";
import { localDateTime } from "./adminUi";
import { canApplyCredits } from "./UserWorkspaceBillingModel";
import { messages } from "@comma/i18n";

export type CatalogState =
  | { readonly status: "loading" }
  | { readonly status: "error"; readonly message: string }
  | {
      readonly status: "ready";
      readonly codes: ReadonlyArray<CatalogRedeemCode>;
      readonly packageNotice?: string;
      readonly packages: ReadonlyArray<AdminPackageVersion>;
    };

export type BillingDrawer =
  | { readonly kind: "apply"; readonly model: ApplyCodeModel }
  | { readonly kind: "code"; readonly model: RedeemCodeModel }
  | { readonly kind: "create"; readonly model: CreateCodeModel };

export interface BillingState {
  readonly catalog: CatalogState;
  readonly drawer: BillingDrawer | undefined;
  readonly notice: string | undefined;
}

export interface BillingModel {
  readonly state: SubscriptionRef.SubscriptionRef<BillingState>;
  readonly reload: Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  readonly openApply: Effect.Effect<void>;
  readonly openCreate: Effect.Effect<void>;
  readonly openCode: (code: CatalogRedeemCode) => Effect.Effect<void>;
  readonly closeDrawer: Effect.Effect<void>;
}

type DrawerServices = AdminApi | AdminBrowser | AdminShellLinks;

/** Opens Redeem codes; a `target` from Users opens the apply drawer for it once codes load. */
export const makeBillingModel = (target: AdminRedeemTarget | undefined) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const links = yield* AdminShellLinks;
    const failures = yield* makeFailures;
    const scope = yield* Effect.scope;
    const services = yield* Effect.context<DrawerServices>();
    const state = yield* SubscriptionRef.make<BillingState>({
      catalog: { status: "loading" },
      drawer: undefined,
      notice: undefined,
    });
    const loading = yield* FiberHandle.make();
    let applyTarget = target;
    let drawerScope: Scope.Closeable | undefined;

    const update = (change: (current: BillingState) => BillingState) =>
      SubscriptionRef.update(state, change);

    const closeDrawerScope = Effect.suspend(() => {
      const open = drawerScope;
      drawerScope = undefined;
      return open ? Scope.close(open, Exit.void) : Effect.void;
    });

    const openDrawer = (
      make: Effect.Effect<BillingDrawer, never, DrawerServices | Scope.Scope>
    ) =>
      Effect.gen(function* () {
        yield* closeDrawerScope;
        const child = yield* Scope.fork(scope);
        drawerScope = child;
        const drawer = yield* make.pipe(
          Scope.provide(child),
          Effect.provideContext(services)
        );
        yield* update((current) => ({ ...current, drawer }));
      });

    const closeDrawer = Effect.gen(function* () {
      yield* update((current) => ({ ...current, drawer: undefined }));
      yield* closeDrawerScope;
    });

    /** Shows `message`, and puts `updatedCode` into the catalog in place (or first, when new). */
    const completed = (message: string, updatedCode?: CatalogRedeemCode) =>
      update((current) => {
        const { catalog } = current;
        if (!updatedCode || catalog.status !== "ready")
          return { ...current, notice: message };
        const exists = catalog.codes.some((code) => code.id === updatedCode.id);
        return {
          ...current,
          catalog: {
            ...catalog,
            codes: exists
              ? catalog.codes.map((code) =>
                  code.id === updatedCode.id ? updatedCode : code
                )
              : [updatedCode, ...catalog.codes],
          },
          notice: message,
        };
      });

    const openCode = (code: CatalogRedeemCode) =>
      openDrawer(
        Effect.map(
          makeRedeemCodeModel(code, (changed, message) => completed(message, changed)),
          (model) => ({ kind: "code", model })
        )
      );

    const openApply = (applyFor: AdminRedeemTarget | undefined) =>
      Effect.gen(function* () {
        const { catalog } = yield* SubscriptionRef.get(state);
        if (catalog.status !== "ready") return;
        yield* openDrawer(
          Effect.map(
            makeApplyCodeModel(catalog.codes, applyFor, (code, result) =>
              Effect.gen(function* () {
                yield* openCode(code);
                yield* completed(
                  result.idempotent
                    ? messages.admin_code_applied_before({ code: displayPrefix(code) })
                    : messages.admin_code_applied({ code: displayPrefix(code) })
                );
              })
            ),
            (model) => ({ kind: "apply", model })
          )
        );
      });

    const openCreate = Effect.gen(function* () {
      const { catalog } = yield* SubscriptionRef.get(state);
      if (catalog.status !== "ready") return;
      yield* openDrawer(
        Effect.map(
          makeCreateCodeModel(catalog.packages, (code) =>
            completed(
              messages.admin_code_created_notice({ code: displayPrefix(code) }),
              code
            )
          ),
          (model) => ({ kind: "create", model })
        )
      );
    });

    const load = Effect.gen(function* () {
      yield* update((current) => ({ ...current, catalog: { status: "loading" } }));
      const [codes, packages] = yield* Effect.all(
        [
          api.listRedeemCodes({ limit: billingViewLimit }).pipe(
            Effect.map((list) => list.map(withoutRedeemCodePlaintext)),
            Effect.result
          ),
          api.listPackageVersions.pipe(Effect.result),
        ],
        { concurrency: "unbounded" }
      );
      const rejected = [
        ...(Result.isFailure(codes) ? [codes.failure] : []),
        ...(Result.isFailure(packages) ? [packages.failure] : []),
      ];
      if (rejected.some(isAdminAccessDenied)) {
        yield* links.denyAccess;
        return;
      }
      if (rejected.some(isAdminSessionRejection)) return;
      if (Result.isFailure(codes)) {
        const message = yield* failures.read(
          codes.failure,
          messages.admin_codes_load_error()
        );
        if (message) {
          yield* update((current) => ({
            ...current,
            catalog: { status: "error", message },
          }));
        }
        return;
      }
      yield* update((current) => ({
        ...current,
        catalog: {
          status: "ready",
          codes: codes.success,
          packages: Result.isSuccess(packages) ? packages.success : [],
          ...(Result.isFailure(packages)
            ? {
                packageNotice: messages.admin_package_labels_unavailable(),
              }
            : {}),
        },
      }));
      // The target Users prepared is applied once, on the first catalog it can use.
      if (applyTarget) {
        const applyFor = applyTarget;
        applyTarget = undefined;
        yield* openApply(applyFor);
      }
    });
    const reload = FiberHandle.run(loading, load).pipe(Effect.asVoid);
    yield* reload;

    const model: BillingModel = {
      state,
      reload,
      dismissNotice: update((current) => ({ ...current, notice: undefined })),
      openApply: openApply(undefined),
      openCreate,
      openCode,
      closeDrawer,
    };
    return model;
  });

/** Runs `command`, failing with the message a failed command shows. */
const commandFailure =
  (failures: Failures) =>
  <A, E>(command: Effect.Effect<A, E>) =>
    command.pipe(
      Effect.catch((error) =>
        failures.command(error).pipe(Effect.flatMap((message) => Effect.fail(message)))
      )
    );

export interface CreateCodeState {
  readonly copied: boolean;
  /** The command's result; a created code's plaintext stays only here, while the drawer is open. */
  readonly created: AdminRedeemCodeCreation | undefined;
  readonly customCode: string;
  readonly expiresAt: string;
  readonly maxRedemptions: number;
  readonly packageKey: string;
  readonly perAccountLimit: number;
}

export type CreateCodeField = "customCode" | "expiresAt" | "packageKey";

export interface CreateCodeModel {
  readonly state: SubscriptionRef.SubscriptionRef<CreateCodeState>;
  readonly confirmation: Confirmation;
  readonly packages: ReadonlyArray<AdminPackageVersion>;
  readonly setField: (field: CreateCodeField, value: string) => Effect.Effect<void>;
  readonly setLimit: (
    field: "maxRedemptions" | "perAccountLimit",
    value: number
  ) => Effect.Effect<void>;
  readonly review: Effect.Effect<void>;
  readonly copyCode: Effect.Effect<void>;
}

const makeCreateCodeModel = (
  packages: ReadonlyArray<AdminPackageVersion>,
  onCreated: (code: CatalogRedeemCode) => Effect.Effect<void>
) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const browser = yield* AdminBrowser;
    const command = commandFailure(yield* makeFailures);
    const confirmation = yield* makeConfirmation;
    const firstPackage = packages[0];
    const state = yield* SubscriptionRef.make<CreateCodeState>({
      copied: false,
      created: undefined,
      customCode: "",
      expiresAt: "",
      maxRedemptions: 10,
      packageKey: firstPackage ? packageVersionKey(firstPackage) : "",
      perAccountLimit: 1,
    });
    // One key for the drawer: every try of this create is the same command.
    const idempotencyKey = yield* Effect.sync(() =>
      createIdempotencyKey("create-code")
    );

    const update = (change: (current: CreateCodeState) => CreateCodeState) =>
      SubscriptionRef.update(state, change);

    const create = (key: string, reason: string) =>
      Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        const selected = selectedPackage(packages, current.packageKey);
        if (!selected)
          return yield* Effect.fail(messages.admin_select_issuable_package());
        const customCode = current.customCode.trim();
        const expiresAt = current.expiresAt
          ? yield* Option.match(localDateTime(current.expiresAt), {
              onNone: () => Effect.fail(messages.admin_invalid_date()),
              onSome: (date) => Effect.succeed(DateTime.formatIso(date)),
            })
          : undefined;
        const code = yield* command(
          api.createRedeemCode({
            ...(customCode ? { code: customCode } : {}),
            confirmation: createExpected(selected),
            ...(expiresAt ? { expiresAt } : {}),
            idempotencyKey: key,
            maxRedemptions: current.maxRedemptions,
            packageCode: selected.package_code,
            packageVersion: selected.version,
            perAccountLimit: current.perAccountLimit,
            reason,
          })
        );
        yield* update((value) => ({ ...value, created: code }));
        yield* onCreated(withoutRedeemCodePlaintext(code.record));
      });

    const model: CreateCodeModel = {
      state,
      confirmation,
      packages,
      setField: (field, value) => update((current) => ({ ...current, [field]: value })),
      setLimit: (field, value) => update((current) => ({ ...current, [field]: value })),
      review: Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        const selected = selectedPackage(packages, current.packageKey);
        if (!selected) return;
        yield* confirmation.open({
          changes: [
            {
              label: messages.admin_package(),
              before: "—",
              after: `${selected.package_code} v${selected.version}`,
            },
          ],
          key: idempotencyKey,
          keyPrefix: "create-code",
          run: create,
          title: messages.admin_create_code_title(),
        });
      }),
      copyCode: Effect.gen(function* () {
        const { created } = yield* SubscriptionRef.get(state);
        if (created?.kind !== "created") return;
        yield* browser.copy(created.record.code);
        yield* update((current) => ({ ...current, copied: true }));
      }).pipe(Effect.ignore),
    };
    return model;
  });

/** Whether the account the operator chose has a Workspace that can take a code. */
export type ApplyAccount =
  | { readonly status: "idle" }
  | { readonly status: "loading"; readonly email: string }
  | { readonly status: "error"; readonly message: string };

export interface ApplyCodeState {
  readonly account: ApplyAccount;
  readonly codeId: string;
  /** The Workspace the code is applied to, from Users or from the account the operator chose. */
  readonly target: AdminRedeemTarget | undefined;
}

export interface ApplyCodeModel {
  readonly state: SubscriptionRef.SubscriptionRef<ApplyCodeState>;
  readonly confirmation: Confirmation;
  readonly codes: ReadonlyArray<CatalogRedeemCode>;
  /** Finds the account by email or by any id it is known by, like ⌘K. */
  readonly search: SearchModel;
  readonly setCode: (codeId: string) => Effect.Effect<void>;
  /** Reads the chosen account's Workspace and makes it the target. */
  readonly chooseAccount: (result: AdminLookupResult) => Effect.Effect<void>;
  readonly changeAccount: Effect.Effect<void>;
  readonly review: Effect.Effect<void>;
}

const makeApplyCodeModel = (
  codes: ReadonlyArray<CatalogRedeemCode>,
  target: AdminRedeemTarget | undefined,
  onApplied: (
    code: CatalogRedeemCode,
    result: AdminRedemptionResult
  ) => Effect.Effect<void>
) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const failures = yield* makeFailures;
    const command = commandFailure(failures);
    const confirmation = yield* makeConfirmation;
    const search = yield* makeSearchModel;
    const state = yield* SubscriptionRef.make<ApplyCodeState>({
      account: { status: "idle" },
      codeId: codes.find((code) => code.status === "active")?.id ?? "",
      target,
    });
    const choosing = yield* FiberHandle.make();
    const idempotencyKey = yield* Effect.sync(() => createIdempotencyKey("apply-code"));
    const update = (change: (current: ApplyCodeState) => ApplyCodeState) =>
      SubscriptionRef.update(state, change);

    const apply = (key: string, reason: string) =>
      Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        const selected = codes.find((code) => code.id === current.codeId);
        if (!selected) return yield* Effect.fail("Select an active redeem code.");
        const chosen = current.target;
        if (!chosen) return yield* Effect.fail(messages.admin_apply_choose_account());
        const result = yield* command(
          api.applyRedeemCode({
            billingAccountId: chosen.billingAccountId,
            codeId: selected.id,
            confirmation: applyExpected(chosen),
            idempotencyKey: key,
            productOwnerId: chosen.productOwnerId,
            productOwnerType: "workspace",
            reason,
          })
        );
        yield* onApplied(selected, result);
      });

    const readAccount = (result: AdminLookupResult) =>
      Effect.gen(function* () {
        // An account signed in without email (Apple, a paired watch) goes by its id.
        const label = result.user.email || result.user.id;
        yield* update((current) => ({
          ...current,
          account: { status: "loading", email: label },
        }));
        const read = yield* Effect.result(api.getUserWorkspaceBilling(result.user.id));
        if (Result.isFailure(read)) {
          const message = yield* failures.read(
            read.failure,
            messages.admin_apply_account_failed()
          );
          yield* update((current) => ({
            ...current,
            account: message ? { status: "error", message } : { status: "idle" },
          }));
          return;
        }
        const overview = read.success;
        const workspace = overview.workspace;
        if (!workspace || !canApplyCredits(overview)) {
          yield* update((current) => ({
            ...current,
            account: {
              status: "error",
              message: workspace
                ? messages.admin_apply_workspace_unavailable({
                    email: label,
                  })
                : messages.admin_apply_no_workspace({ email: label }),
            },
          }));
          return;
        }
        yield* update((current) => ({
          ...current,
          account: { status: "idle" },
          target: {
            accountLabel: label,
            billingAccountId: workspace.billing_account_id,
            productOwnerId: workspace.id,
            productOwnerType: "workspace",
            ...(workspace.name ? { workspaceName: workspace.name } : {}),
          },
        }));
        yield* search.setOpen(false);
      });

    const model: ApplyCodeModel = {
      state,
      confirmation,
      codes,
      search,
      setCode: (codeId) => update((current) => ({ ...current, codeId })),
      chooseAccount: (result) =>
        FiberHandle.run(choosing, readAccount(result)).pipe(Effect.asVoid),
      changeAccount: Effect.gen(function* () {
        yield* FiberHandle.clear(choosing);
        yield* update((current) => ({
          ...current,
          account: { status: "idle" },
          target: undefined,
        }));
      }),
      review: confirmation.open({
        key: idempotencyKey,
        keyPrefix: "apply-code",
        run: apply,
        title: messages.admin_apply_code_title(),
      }),
    };
    return model;
  });

export type RedemptionsState =
  | { readonly status: "loading" }
  | { readonly status: "error"; readonly message: string }
  | { readonly status: "ready"; readonly redemptions: ReadonlyArray<AdminRedemption> };

export interface RedeemCodeState {
  readonly code: CatalogRedeemCode;
  readonly redemptions: RedemptionsState;
}

export interface RedeemCodeModel {
  readonly state: SubscriptionRef.SubscriptionRef<RedeemCodeState>;
  readonly confirmation: Confirmation;
  readonly reload: Effect.Effect<void>;
  readonly reviewDisable: Effect.Effect<void>;
}

const makeRedeemCodeModel = (
  code: CatalogRedeemCode,
  onChanged: (code: CatalogRedeemCode, message: string) => Effect.Effect<void>
) =>
  Effect.gen(function* () {
    const api = yield* AdminApi;
    const failures = yield* makeFailures;
    const command = commandFailure(failures);
    const confirmation = yield* makeConfirmation;
    const state = yield* SubscriptionRef.make<RedeemCodeState>({
      code,
      redemptions: { status: "loading" },
    });
    const loading = yield* FiberHandle.make();
    const idempotencyKey = yield* Effect.sync(() =>
      createIdempotencyKey("disable-code")
    );
    const expected = `disable-redeem-code:${code.id}`;

    const update = (change: (current: RedeemCodeState) => RedeemCodeState) =>
      SubscriptionRef.update(state, change);

    const load = Effect.gen(function* () {
      yield* update((current) => ({ ...current, redemptions: { status: "loading" } }));
      yield* api
        .listRedemptions({ limit: billingViewLimit, redeemCodeId: code.id })
        .pipe(
          Effect.matchEffect({
            onFailure: (error) =>
              failures.read(error, messages.admin_redemptions_load_error()).pipe(
                Effect.flatMap((message) =>
                  message
                    ? update((current) => ({
                        ...current,
                        redemptions: { status: "error", message },
                      }))
                    : Effect.void
                )
              ),
            onSuccess: (redemptions) =>
              update((current) => ({
                ...current,
                redemptions: { status: "ready", redemptions },
              })),
          })
        );
    });
    const reload = FiberHandle.run(loading, load).pipe(Effect.asVoid);
    yield* reload;

    const disable = (key: string, reason: string) =>
      Effect.gen(function* () {
        const disabled = withoutRedeemCodePlaintext(
          yield* command(
            api.disableRedeemCode(code.id, {
              confirmation: expected,
              idempotencyKey: key,
              reason,
            })
          )
        );
        // The drawer stays on this code (its history too) and shows the disabled record.
        yield* update((current) => ({ ...current, code: disabled }));
        yield* onChanged(
          disabled,
          messages.admin_code_disabled_notice({ code: displayPrefix(code) })
        );
      });

    const model: RedeemCodeModel = {
      state,
      confirmation,
      reload,
      reviewDisable: confirmation.open({
        destructive: true,
        explanation: messages.admin_disable_code_explanation(),
        key: idempotencyKey,
        keyPrefix: "disable-code",
        run: disable,
        title: messages.admin_disable_code_title(),
      }),
    };
    return model;
  });

function createExpected(version: AdminPackageVersion) {
  return `create-redeem-code:${version.package_code}:${version.version}`;
}

function applyExpected(target: AdminRedeemTarget) {
  return `apply-redeem-code:${target.billingAccountId}`;
}

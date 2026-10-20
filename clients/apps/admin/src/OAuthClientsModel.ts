// OAuth clients: the registered applications that use Comma as an OpenID Connect provider, and their audited
// lifecycle. A one-time client secret lives only in its drawer's model: it is never stored, and closing the drawer
// drops it.
import {
  type Context,
  Effect,
  Exit,
  FiberHandle,
  Scope,
  SubscriptionRef,
} from "effect";
import {
  AdminApi,
  AdminApiError,
  createIdempotencyKey,
  type AdminApiShape,
  type AdminOauthClient,
  type AdminOauthClientCreation,
  type AdminOauthClientSecret,
} from "./adminApi";
import { AdminBrowser } from "./adminBrowser";
import {
  makeConfirmation,
  makeFailures,
  type Confirmation,
  type Failures,
} from "./adminModel";
import { messages } from "@comma/i18n";

export type CatalogOauthClient = AdminOauthClient & { client_secret?: never };

export type CatalogState =
  | { readonly status: "loading" }
  | { readonly status: "error"; readonly message: string; readonly title: string }
  | { readonly status: "ready"; readonly clients: ReadonlyArray<CatalogOauthClient> };

export interface OneTimeSecret {
  readonly client: CatalogOauthClient;
  readonly kind: "created" | "rotated";
  readonly value: string;
}

/** A one-time secret as its drawer shows it. */
export interface ShownSecret {
  readonly copied: boolean;
  readonly secret: OneTimeSecret;
}

export type OauthClientType = "confidential" | "public";

export interface CreateClientState {
  readonly clientType: OauthClientType;
  /** The created client, without its secret. */
  readonly created: CatalogOauthClient | undefined;
  readonly name: string;
  readonly redirectText: string;
  /** The created client's secret, once created. */
  readonly secret: ShownSecret | undefined;
}

export type CreateClientField = "name" | "redirectText";

export interface CreateClientModel {
  readonly state: SubscriptionRef.SubscriptionRef<CreateClientState>;
  readonly confirmation: Confirmation;
  readonly setField: (field: CreateClientField, value: string) => Effect.Effect<void>;
  readonly setClientType: (clientType: OauthClientType) => Effect.Effect<void>;
  readonly review: Effect.Effect<void>;
  readonly copySecret: Effect.Effect<void>;
}

export type LifecycleAction = "disable" | "enable" | "rotate";

export interface ClientDetailsState {
  readonly client: CatalogOauthClient;
  /** A rotated secret; its drawer replaces the details until it is cleared. */
  readonly secret: ShownSecret | undefined;
}

export interface ClientDetailsModel {
  readonly state: SubscriptionRef.SubscriptionRef<ClientDetailsState>;
  readonly confirmation: Confirmation;
  readonly review: (action: LifecycleAction) => Effect.Effect<void>;
  readonly copySecret: Effect.Effect<void>;
  readonly clearSecret: Effect.Effect<void>;
}

export type OAuthClientsDrawer =
  | { readonly kind: "create"; readonly model: CreateClientModel }
  | { readonly kind: "client"; readonly model: ClientDetailsModel };

export interface OAuthClientsState {
  readonly catalog: CatalogState;
  readonly drawer: OAuthClientsDrawer | undefined;
  readonly notice: string | undefined;
}

export interface OAuthClientsModel {
  readonly state: SubscriptionRef.SubscriptionRef<OAuthClientsState>;
  readonly reload: Effect.Effect<void>;
  readonly dismissNotice: Effect.Effect<void>;
  readonly openCreate: Effect.Effect<void>;
  readonly openClient: (client: CatalogOauthClient) => Effect.Effect<void>;
  readonly closeDrawer: Effect.Effect<void>;
}

/** What a drawer's commands tell the catalog. */
type Completed = (client: CatalogOauthClient, message: string) => Effect.Effect<void>;

interface DrawerContext {
  readonly api: AdminApiShape;
  readonly browser: Browser;
  readonly completed: Completed;
  readonly failures: Failures;
}

type Browser = Context.Service.Shape<typeof AdminBrowser>;

const copySecretOf = <S extends { readonly secret: ShownSecret | undefined }>(
  browser: Browser,
  state: SubscriptionRef.SubscriptionRef<S>
) =>
  Effect.gen(function* () {
    const shown = (yield* SubscriptionRef.get(state)).secret;
    if (!shown) return;
    yield* browser.copy(shown.secret.value);
    yield* SubscriptionRef.update(state, (current) =>
      current.secret?.secret === shown.secret
        ? { ...current, secret: { ...shown, copied: true } }
        : current
    );
  }).pipe(Effect.ignore);

/** The form fields as the create command sends them. */
export function createClientForm(state: CreateClientState) {
  const normalizedName = state.name.trim().replace(/\s+/g, " ");
  const redirectUris = parseRedirectUris(state.redirectText);
  return {
    expected: `create-oauth-client:${normalizedName}`,
    formReady:
      normalizedName.length >= 3 &&
      normalizedName.length <= 64 &&
      redirectUris.length >= 1 &&
      redirectUris.length <= 8,
    normalizedName,
    redirectUris,
  };
}

const makeCreateClientModel = ({ api, browser, completed, failures }: DrawerContext) =>
  Effect.gen(function* () {
    const state = yield* SubscriptionRef.make<CreateClientState>({
      clientType: "confidential",
      created: undefined,
      name: "",
      redirectText: "",
      secret: undefined,
    });
    const confirmation = yield* makeConfirmation;
    // One key for every try from this drawer: a retried create is the same command.
    const idempotencyKey = yield* Effect.sync(() =>
      createIdempotencyKey("create-oauth-client")
    );
    const update = (change: (current: CreateClientState) => CreateClientState) =>
      SubscriptionRef.update(state, change);

    const create = (expected: string) => (key: string, reason: string) =>
      Effect.gen(function* () {
        const current = yield* SubscriptionRef.get(state);
        const form = createClientForm(current);
        const result = yield* api
          .createOauthClient({
            confidential: current.clientType === "confidential",
            confirmation: expected,
            idempotencyKey: key,
            name: form.normalizedName,
            reason,
            redirectUris: form.redirectUris,
          })
          .pipe(Effect.catch((error) => Effect.flip(failures.command(error))));
        const client = withoutOauthClientSecret(result);
        yield* completed(client, messages.admin_created_client({ name: client.name }));
        yield* update((value) => ({
          ...value,
          created: client,
          secret:
            "client_secret" in result
              ? {
                  copied: false,
                  secret: { client, kind: "created", value: result.client_secret },
                }
              : undefined,
        }));
      });

    const model: CreateClientModel = {
      state,
      confirmation,
      setField: (field, value) => update((current) => ({ ...current, [field]: value })),
      setClientType: (clientType) => update((current) => ({ ...current, clientType })),
      review: Effect.gen(function* () {
        const { expected } = createClientForm(yield* SubscriptionRef.get(state));
        yield* confirmation.open({
          key: idempotencyKey,
          keyPrefix: "create-oauth-client",
          run: create(expected),
          title: messages.admin_create_client_title(),
        });
      }),
      copySecret: copySecretOf(browser, state),
    };
    return model;
  });

const makeClientDetailsModel = (
  { api, browser, completed, failures }: DrawerContext,
  client: CatalogOauthClient
) =>
  Effect.gen(function* () {
    const state = yield* SubscriptionRef.make<ClientDetailsState>({
      client,
      secret: undefined,
    });
    const confirmation = yield* makeConfirmation;
    const update = (change: (current: ClientDetailsState) => ClientDetailsState) =>
      SubscriptionRef.update(state, change);
    const guarded = <A>(command: Effect.Effect<A, unknown>) =>
      command.pipe(Effect.catch((error) => Effect.flip(failures.command(error))));

    const changed = (updated: CatalogOauthClient, message: string) =>
      Effect.gen(function* () {
        yield* update((current) => ({ ...current, client: updated }));
        yield* completed(updated, message);
      });

    const run =
      (action: LifecycleAction, expected: string) => (key: string, reason: string) =>
        Effect.gen(function* () {
          const { client: current } = yield* SubscriptionRef.get(state);
          const metadata = { confirmation: expected, idempotencyKey: key, reason };

          if (action === "rotate") {
            const result = yield* guarded(
              api.rotateOauthClientSecret(current.id, metadata)
            );
            const updated = withoutOauthClientSecret(result);
            yield* changed(
              updated,
              messages.admin_rotated_client({ name: current.name })
            );
            yield* update((value) => ({
              ...value,
              secret: {
                copied: false,
                secret: {
                  client: updated,
                  kind: "rotated",
                  value: result.client_secret,
                },
              },
            }));
            return;
          }

          const updated = yield* guarded(
            action === "disable"
              ? api.disableOauthClient(current.id, metadata)
              : api.enableOauthClient(current.id, metadata)
          );
          yield* changed(
            withoutOauthClientSecret(updated),
            action === "disable"
              ? messages.admin_disabled_client({ name: current.name })
              : messages.admin_enabled_client({ name: current.name })
          );
        });

    const model: ClientDetailsModel = {
      state,
      confirmation,
      review: (action) =>
        Effect.gen(function* () {
          const { client: current } = yield* SubscriptionRef.get(state);
          const slug =
            action === "rotate"
              ? "rotate-oauth-client-secret"
              : `${action}-oauth-client`;
          const expected = `${slug}:${current.id}`;
          yield* confirmation.open({
            destructive: action !== "enable",
            ...(action === "rotate"
              ? {
                  explanation: messages.admin_rotate_explanation(),
                }
              : action === "disable"
                ? {
                    explanation: messages.admin_disable_client_explanation(),
                  }
                : {}),
            keyPrefix: slug,
            run: run(action, expected),
            title: lifecycleTitle(action),
            ...(action === "enable" ? {} : { typed: current.name }),
          });
        }),
      copySecret: copySecretOf(browser, state),
      clearSecret: update((current) => ({ ...current, secret: undefined })),
    };
    return model;
  });

export const makeOAuthClientsModel = Effect.gen(function* () {
  const api = yield* AdminApi;
  const browser = yield* AdminBrowser;
  const failures = yield* makeFailures;
  const scope = yield* Effect.scope;
  const loading = yield* FiberHandle.make();
  const state = yield* SubscriptionRef.make<OAuthClientsState>({
    catalog: { status: "loading" },
    drawer: undefined,
    notice: undefined,
  });
  let drawerScope: Scope.Closeable | undefined;

  const update = (change: (current: OAuthClientsState) => OAuthClientsState) =>
    SubscriptionRef.update(state, change);

  const load = Effect.gen(function* () {
    yield* update((current) => ({ ...current, catalog: { status: "loading" } }));
    yield* api.listOauthClients.pipe(
      Effect.matchEffect({
        onFailure: (error) =>
          failures.read(error, messages.admin_oauth_load_error()).pipe(
            Effect.flatMap((message) => {
              if (!message) return Effect.void;
              const disabled = error instanceof AdminApiError && error.status === 404;
              return update((current) => ({
                ...current,
                catalog: {
                  status: "error",
                  message: disabled ? messages.admin_oauth_disabled_body() : message,
                  title: disabled
                    ? messages.admin_oauth_disabled()
                    : messages.admin_oauth_load_failed(),
                },
              }));
            })
          ),
        onSuccess: (clients) =>
          update((current) => ({
            ...current,
            catalog: {
              status: "ready",
              clients: clients.map(withoutOauthClientSecret),
            },
          })),
      })
    );
  });
  const reload = FiberHandle.run(loading, load).pipe(Effect.asVoid);
  yield* reload;

  const completed: Completed = (client, message) =>
    update((current) => {
      if (current.catalog.status !== "ready") return { ...current, notice: message };
      const { clients } = current.catalog;
      const exists = clients.some((entry) => entry.id === client.id);
      return {
        ...current,
        catalog: {
          status: "ready",
          clients: exists
            ? clients.map((entry) => (entry.id === client.id ? client : entry))
            : [client, ...clients],
        },
        notice: message,
      };
    });
  const context: DrawerContext = { api, browser, completed, failures };

  const closeDrawer = Effect.gen(function* () {
    const closing = drawerScope;
    drawerScope = undefined;
    yield* update((current) => ({ ...current, drawer: undefined }));
    if (closing) yield* Scope.close(closing, Exit.void);
  });

  const openDrawer = <D extends OAuthClientsDrawer>(
    make: Effect.Effect<D, never, Scope.Scope>
  ) =>
    Effect.gen(function* () {
      yield* closeDrawer;
      const child = yield* Scope.fork(scope);
      drawerScope = child;
      const drawer = yield* Scope.provide(make, child);
      yield* update((current) => ({ ...current, drawer }));
    });

  const model: OAuthClientsModel = {
    state,
    reload,
    dismissNotice: update((current) => ({ ...current, notice: undefined })),
    openCreate: openDrawer(
      Effect.map(makeCreateClientModel(context), (create) => ({
        kind: "create" as const,
        model: create,
      }))
    ),
    openClient: (client) =>
      openDrawer(
        Effect.map(makeClientDetailsModel(context, client), (details) => ({
          kind: "client" as const,
          model: details,
        }))
      ),
    closeDrawer,
  };
  return model;
});

export function withoutOauthClientSecret(
  client: AdminOauthClient | AdminOauthClientCreation | AdminOauthClientSecret
): CatalogOauthClient {
  const catalogClient: Record<string, unknown> = { ...client };
  delete catalogClient.client_secret;
  return catalogClient as CatalogOauthClient;
}

function parseRedirectUris(value: string) {
  return value
    .split(/\r?\n/)
    .map((uri) => uri.trim())
    .filter(Boolean);
}

function lifecycleTitle(action: LifecycleAction): string {
  switch (action) {
    case "rotate":
      return messages.admin_rotate_title();
    case "disable":
      return messages.admin_disable_client_title();
    case "enable":
      return messages.admin_enable_client_title();
  }
}

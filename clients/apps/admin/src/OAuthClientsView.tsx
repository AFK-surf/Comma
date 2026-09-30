import { Badge, Button, InputField, PlusIcon, ScrollArea } from "@comma/ui";
import { useEffect, useMemo, useState } from "react";
import {
  AdminApiError,
  createIdempotencyKey,
  isAdminAccessDenied,
  isAdminSessionRejection,
  type AdminApi,
  type AdminOauthClient,
  type AdminOauthClientCreation,
  type AdminOauthClientSecret,
} from "./adminApi";
import { adminErrorMessage, guardedAdminCommand } from "./adminErrors";
import {
  AdminConfirmationDialog,
  AdminDrawer,
  AdminNotice,
  AdminPageHeader,
  AdminState,
  DetailList,
  NativeField,
  ReasonField,
  StatusBadge,
  formatIso,
} from "./adminUi";

const oauthClientLimit = 200;

export type CatalogOauthClient = AdminOauthClient & { client_secret?: never };

type CatalogState =
  | { status: "loading" }
  | { status: "error"; message: string; title: string }
  | { status: "ready"; clients: CatalogOauthClient[] };

type ClientDrawer = { kind: "client"; client: CatalogOauthClient } | { kind: "create" };

type LifecycleAction = "disable" | "enable" | "rotate";

interface PendingCommand {
  action: LifecycleAction;
  confirmation: string;
  idempotencyKey: string;
}

interface OneTimeSecret {
  client: CatalogOauthClient;
  kind: "created" | "rotated";
  value: string;
}

export function OAuthClientsView({
  api,
  onAccessDenied,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
}) {
  const [drawer, setDrawer] = useState<ClientDrawer>();
  const [notice, setNotice] = useState<string>();
  const [revision, setRevision] = useState(0);
  const [state, setState] = useState<CatalogState>({ status: "loading" });

  useEffect(() => {
    const request = new AbortController();
    setState({ status: "loading" });

    void api
      .listOauthClients({ signal: request.signal })
      .then((clients) => {
        if (!request.signal.aborted) {
          setState({ status: "ready", clients: clients.map(withoutOauthClientSecret) });
        }
      })
      .catch((error: unknown) => {
        if (request.signal.aborted || isAdminSessionRejection(error)) return;
        if (isAdminAccessDenied(error)) {
          onAccessDenied();
          return;
        }

        setState({
          status: "error",
          message:
            error instanceof AdminApiError && error.status === 404
              ? "Enable the Comma OAuth IdP before registering clients."
              : adminErrorMessage(error, "Unable to load OAuth clients."),
          title:
            error instanceof AdminApiError && error.status === 404
              ? "OAuth IdP isn’t enabled"
              : "OAuth clients couldn’t be loaded",
        });
      });

    return () => request.abort();
  }, [api, onAccessDenied, revision]);

  const completed = (client: CatalogOauthClient, message: string) => {
    setNotice(message);
    setState((current) => {
      if (current.status !== "ready") return current;
      const exists = current.clients.some((entry) => entry.id === client.id);
      return {
        status: "ready",
        clients: exists
          ? current.clients.map((entry) => (entry.id === client.id ? client : entry))
          : [client, ...current.clients],
      };
    });
  };

  const ready = state.status === "ready" ? state : undefined;

  return (
    <section
      aria-label="OAuth clients"
      className="admin-workspace"
      data-testid="admin-oauth-clients"
    >
      <AdminPageHeader
        actions={
          <Button
            iconLeading={<PlusIcon />}
            isDisabled={!ready}
            onPress={() => setDrawer({ kind: "create" })}
          >
            New client
          </Button>
        }
        description="Register and control the applications that use Comma as an OpenID Connect provider."
        eyebrow="Identity provider"
        title="OAuth clients"
      />

      {notice ? (
        <AdminNotice message={notice} onDismiss={() => setNotice(undefined)} />
      ) : null}

      <div className="admin-table-card">
        <div className="admin-table-card-header">
          <div>
            <h2>Registered clients</h2>
            <p>Secrets are never returned by this bounded Admin query</p>
          </div>
          <Button
            hierarchy="secondary-gray"
            onPress={() => setRevision((current) => current + 1)}
            size="sm"
          >
            Refresh
          </Button>
        </div>

        <ClientCatalog
          onRetry={() => setRevision((current) => current + 1)}
          onSelect={(client) => setDrawer({ kind: "client", client })}
          state={state}
        />
      </div>

      {drawer?.kind === "create" && ready ? (
        <CreateClientDrawer
          api={api}
          onAccessDenied={onAccessDenied}
          onClose={() => setDrawer(undefined)}
          onCreated={(client) => completed(client, `Created ${client.name}.`)}
        />
      ) : null}

      {drawer?.kind === "client" ? (
        <ClientDetailsDrawer
          api={api}
          client={drawer.client}
          onAccessDenied={onAccessDenied}
          onChanged={(client, message) => {
            setDrawer({ kind: "client", client });
            completed(client, message);
          }}
          onClose={() => setDrawer(undefined)}
        />
      ) : null}
    </section>
  );
}

function ClientCatalog({
  onRetry,
  onSelect,
  state,
}: {
  onRetry: () => void;
  onSelect: (client: CatalogOauthClient) => void;
  state: CatalogState;
}) {
  if (state.status === "loading") {
    return (
      <AdminState
        message="Fetching the registered client projections."
        title="Loading OAuth clients…"
      />
    );
  }
  if (state.status === "error") {
    return (
      <AdminState
        message={state.message}
        onAction={onRetry}
        title={state.title}
        tone="error"
      />
    );
  }
  if (state.clients.length === 0) {
    return (
      <AdminState
        message="Register the first approved application that will use Comma for sign-in."
        title="No OAuth clients"
      />
    );
  }

  return (
    <>
      <ScrollArea
        className="admin-table-scroll"
        contentClassName="admin-table-content admin-oauth-table-content"
        edgeEffect="none"
        orientation="both"
        scrollbarVisibility="hover"
        viewportClassName="admin-table-viewport"
      >
        <table aria-label="OAuth clients" className="admin-data-table">
          <thead>
            <tr>
              <th scope="col">Client</th>
              <th scope="col">Type</th>
              <th scope="col">Status</th>
              <th scope="col">Redirect URIs</th>
              <th scope="col">Created</th>
              <th aria-label="Manage client" scope="col" />
            </tr>
          </thead>
          <tbody>
            {state.clients.map((client) => (
              <tr key={client.id}>
                <th aria-label={`${client.name}, ${client.id}`} scope="row">
                  <div className="admin-primary-cell">
                    <strong>{client.name}</strong>
                    <span>{client.id}</span>
                  </div>
                </th>
                <td>{client.confidential ? "Confidential" : "Public (PKCE)"}</td>
                <td>
                  <StatusBadge status={clientStatus(client)} />
                </td>
                <td>{redirectUriSummary(client.redirect_uris)}</td>
                <td>{formatIso(client.created_at)}</td>
                <td className="admin-row-action-cell">
                  <Button
                    hierarchy="secondary-gray"
                    onPress={() => onSelect(client)}
                    size="sm"
                  >
                    Manage
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </ScrollArea>
      <div className="admin-table-footer">
        <p>
          Showing {state.clients.length} of up to {oauthClientLimit} registered clients
        </p>
      </div>
    </>
  );
}

function CreateClientDrawer({
  api,
  onAccessDenied,
  onClose,
  onCreated,
}: {
  api: AdminApi;
  onAccessDenied: () => void;
  onClose: () => void;
  onCreated: (client: CatalogOauthClient) => void;
}) {
  const [clientType, setClientType] = useState<"confidential" | "public">(
    "confidential"
  );
  const [commandBusy, setCommandBusy] = useState(false);
  const [confirmationOpen, setConfirmationOpen] = useState(false);
  const [created, setCreated] = useState<AdminOauthClientCreation>();
  const [idempotencyKey] = useState(() => createIdempotencyKey("create-oauth-client"));
  const [name, setName] = useState("");
  const [reason, setReason] = useState("");
  const [redirectText, setRedirectText] = useState("");
  const redirectUris = useMemo(() => parseRedirectUris(redirectText), [redirectText]);
  const normalizedName = name.trim().replace(/\s+/g, " ");
  const expected = `create-oauth-client:${normalizedName}`;

  if (created) {
    const client = withoutOauthClientSecret(created);

    if ("client_secret" in created) {
      return (
        <ClientSecretDrawer
          secret={{ client, kind: "created", value: created.client_secret }}
          onClear={onClose}
        />
      );
    }

    return (
      <AdminDrawer
        eyebrow="OAuth client command"
        onClose={onClose}
        title="Client created"
      >
        <section
          aria-label="Created public OAuth client"
          className="admin-command-section"
        >
          <Badge color="success" size="sm" type="pill-color">
            Active
          </Badge>
          <div>
            <h3>{created.name}</h3>
            <p className="admin-drawer-note">
              This public client authenticates with PKCE and has no client secret.
            </p>
          </div>
          <DetailList
            items={[
              { label: "Client ID", value: created.id },
              { label: "Type", value: "Public (PKCE)" },
            ]}
          />
          <div className="admin-command-actions">
            <Button onPress={onClose}>Done</Button>
          </div>
        </section>
      </AdminDrawer>
    );
  }

  const formReady =
    normalizedName.length >= 3 &&
    normalizedName.length <= 64 &&
    redirectUris.length >= 1 &&
    redirectUris.length <= 8 &&
    reason.trim().length >= 3;

  return (
    <AdminDrawer
      eyebrow="OAuth client command"
      isDismissable={!commandBusy}
      onClose={onClose}
      title="New OAuth client"
    >
      <form
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          setConfirmationOpen(true);
        }}
      >
        <InputField
          label="Client name"
          maxLength={64}
          minLength={3}
          onChange={(event) => setName(event.target.value)}
          required
          value={name}
        />
        <NativeField
          hint="One exact URI per line; 1–8 HTTPS URIs. Literal loopback HTTP is allowed for native development."
          label="Redirect URIs"
        >
          <textarea
            maxLength={4_096}
            onChange={(event) => setRedirectText(event.target.value)}
            required
            rows={5}
            value={redirectText}
          />
        </NativeField>
        <NativeField
          hint="Confidential clients receive a one-time secret; public clients use PKCE only."
          label="Client type"
        >
          <select
            onChange={(event) =>
              setClientType(event.target.value as "confidential" | "public")
            }
            value={clientType}
          >
            <option value="confidential">Confidential</option>
            <option value="public">Public (PKCE)</option>
          </select>
        </NativeField>
        <ReasonField onChange={setReason} value={reason} />
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={onClose}>
            Cancel
          </Button>
          <Button isDisabled={!formReady} type="submit">
            Review command
          </Button>
        </div>
      </form>

      <AdminConfirmationDialog
        expected={expected}
        isOpen={confirmationOpen}
        onBusyChange={setCommandBusy}
        onConfirm={async () => {
          const result = await guardedAdminCommand(
            api.createOauthClient({
              confidential: clientType === "confidential",
              confirmation: expected,
              idempotencyKey,
              name: normalizedName,
              reason: reason.trim(),
              redirectUris,
            }),
            onAccessDenied
          );
          const client = withoutOauthClientSecret(result);
          onCreated(client);
          setCreated(result);
        }}
        onOpenChange={setConfirmationOpen}
        title="Create this OAuth client?"
      />
    </AdminDrawer>
  );
}

function ClientDetailsDrawer({
  api,
  client,
  onAccessDenied,
  onChanged,
  onClose,
}: {
  api: AdminApi;
  client: CatalogOauthClient;
  onAccessDenied: () => void;
  onChanged: (client: CatalogOauthClient, message: string) => void;
  onClose: () => void;
}) {
  const [commandBusy, setCommandBusy] = useState(false);
  const [pending, setPending] = useState<PendingCommand>();
  const [reason, setReason] = useState("");
  const [secret, setSecret] = useState<OneTimeSecret>();

  if (secret) {
    return <ClientSecretDrawer onClear={() => setSecret(undefined)} secret={secret} />;
  }

  const beginCommand = (action: LifecycleAction) => {
    const slug =
      action === "rotate" ? "rotate-oauth-client-secret" : `${action}-oauth-client`;
    setPending({
      action,
      confirmation: `${slug}:${client.id}`,
      idempotencyKey: createIdempotencyKey(slug),
    });
  };
  const status = clientStatus(client);

  return (
    <AdminDrawer
      eyebrow="OAuth client"
      isDismissable={!commandBusy}
      onClose={onClose}
      title="Manage OAuth client"
    >
      <div className="admin-drawer-summary">
        <div>
          <h3>{client.name}</h3>
          <p>{client.confidential ? "Confidential client" : "Public PKCE client"}</p>
        </div>
        <StatusBadge status={status} />
      </div>

      <DetailList
        items={[
          { label: "Client ID", value: client.id },
          { label: "Created", value: formatIso(client.created_at) },
          { label: "Disabled", value: formatIso(client.disabled_at) },
        ]}
      />

      <section className="admin-drawer-section">
        <div className="admin-drawer-section-header">
          <div>
            <h3>Redirect URIs</h3>
            <p>Authorization responses must match one of these exact values.</p>
          </div>
        </div>
        <ul className="admin-uri-list">
          {client.redirect_uris.map((uri) => (
            <li key={uri}>
              <code>{uri}</code>
            </li>
          ))}
        </ul>
      </section>

      <section className="admin-command-section">
        <div className="admin-command-section-header">
          <div>
            <p>Audited lifecycle</p>
            <h3>Client credentials and access</h3>
          </div>
        </div>
        <ReasonField onChange={setReason} value={reason} />
        <div className="admin-command-actions admin-command-actions-split">
          {client.confidential ? (
            <Button
              hierarchy="secondary-gray"
              isDisabled={reason.trim().length < 3}
              onPress={() => beginCommand("rotate")}
            >
              Rotate secret
            </Button>
          ) : (
            <span />
          )}
          {client.disabled_at ? (
            <Button
              isDisabled={reason.trim().length < 3}
              onPress={() => beginCommand("enable")}
            >
              Enable client
            </Button>
          ) : (
            <Button
              hierarchy="destructive"
              isDisabled={reason.trim().length < 3}
              onPress={() => beginCommand("disable")}
            >
              Disable client
            </Button>
          )}
        </div>
      </section>

      <AdminConfirmationDialog
        destructive={pending?.action === "disable"}
        expected={pending?.confirmation ?? ""}
        isOpen={pending !== undefined}
        onBusyChange={setCommandBusy}
        onConfirm={async () => {
          if (!pending) return;
          const metadata = {
            confirmation: pending.confirmation,
            idempotencyKey: pending.idempotencyKey,
            reason: reason.trim(),
          };

          if (pending.action === "rotate") {
            const result = await guardedAdminCommand(
              api.rotateOauthClientSecret(client.id, metadata),
              onAccessDenied
            );
            const updated = withoutOauthClientSecret(result);
            onChanged(updated, `Rotated the secret for ${client.name}.`);
            setReason("");
            setSecret({
              client: updated,
              kind: "rotated",
              value: result.client_secret,
            });
            return;
          }

          const updated = await guardedAdminCommand(
            pending.action === "disable"
              ? api.disableOauthClient(client.id, metadata)
              : api.enableOauthClient(client.id, metadata),
            onAccessDenied
          );
          const catalogClient = withoutOauthClientSecret(updated);
          onChanged(
            catalogClient,
            `${pending.action === "disable" ? "Disabled" : "Enabled"} ${client.name}.`
          );
          setReason("");
        }}
        onOpenChange={(open) => {
          if (!open) setPending(undefined);
        }}
        title={lifecycleTitle(pending?.action)}
      />
    </AdminDrawer>
  );
}

function ClientSecretDrawer({
  onClear,
  secret,
}: {
  onClear: () => void;
  secret: OneTimeSecret;
}) {
  const [copied, setCopied] = useState(false);

  return (
    <AdminDrawer
      eyebrow="OAuth client command"
      isDismissable={false}
      onClose={onClear}
      title={`Client secret ${secret.kind}`}
    >
      <section aria-label="One-time OAuth client secret" className="admin-secret-panel">
        <Badge color="warning" size="sm" type="pill-color">
          Shown once
        </Badge>
        <div>
          <h3>{secret.client.name}</h3>
          <p>
            Copy the secret now. It cannot be recovered after this panel is cleared;
            rotate it to issue another one.
          </p>
        </div>
        <code>{secret.value}</code>
        <DetailList
          items={[
            { label: "Client ID", value: secret.client.id },
            { label: "Type", value: "Confidential" },
          ]}
        />
        <div className="admin-command-actions">
          <Button
            hierarchy="secondary-gray"
            onPress={() => {
              void navigator.clipboard
                .writeText(secret.value)
                .then(() => setCopied(true));
            }}
          >
            {copied ? "Copied" : "Copy secret"}
          </Button>
          <Button onPress={onClear}>Done and clear</Button>
        </div>
      </section>
    </AdminDrawer>
  );
}

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

function clientStatus(client: CatalogOauthClient) {
  return client.disabled_at ? "disabled" : "active";
}

function redirectUriSummary(uris: string[]) {
  if (uris.length === 0) return "—";
  if (uris.length === 1) return uris[0];
  return `${uris[0]} +${uris.length - 1}`;
}

function lifecycleTitle(action: LifecycleAction | undefined) {
  switch (action) {
    case "rotate":
      return "Rotate this client secret?";
    case "disable":
      return "Disable this OAuth client?";
    case "enable":
      return "Enable this OAuth client?";
    default:
      return "Confirm OAuth client command";
  }
}

import { Badge } from "@comma/ui/components/Badge";
import { Button } from "@comma/ui/components/Button";
import { InputField } from "@comma/ui/components/input";
import { PlusIcon } from "@comma/ui/components/icons";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { confirmationBusy } from "./adminModel";
import { useAdminCommand, useAdminState } from "./adminRuntime";
import {
  AdminConfirmationDialog,
  AdminDrawer,
  AdminNotice,
  AdminPageHeader,
  AdminState,
  DetailList,
  NativeField,
  StatusBadge,
  formatIso,
} from "./adminUi";
import {
  createClientForm,
  type CatalogOauthClient,
  type CatalogState,
  type ClientDetailsModel,
  type CreateClientModel,
  type OAuthClientsModel,
  type OauthClientType,
  type ShownSecret,
} from "./OAuthClientsModel";
import { messages } from "@comma/i18n";

const oauthClientLimit = 200;

export function OAuthClientsView({ model }: { model: OAuthClientsModel }) {
  const run = useAdminCommand();
  const { catalog: state, drawer, notice } = useAdminState(model.state);
  const ready = state.status === "ready" ? state : undefined;
  const close = () => run(model.closeDrawer);

  return (
    <section
      aria-label={messages.admin_section_oauth()}
      className="admin-workspace"
      data-testid="admin-oauth-clients"
    >
      <AdminPageHeader
        actions={
          <Button
            iconLeading={<PlusIcon />}
            isDisabled={!ready}
            onPress={() => run(model.openCreate)}
          >
            {messages.admin_new_client()}
          </Button>
        }
        description={messages.admin_oauth_description()}
        title={messages.admin_section_oauth()}
      />

      {notice ? (
        <AdminNotice message={notice} onDismiss={() => run(model.dismissNotice)} />
      ) : null}

      <div className="admin-table-card">
        <div className="admin-table-card-header">
          <div>
            <h2>{messages.admin_registered_clients()}</h2>
            <p>{messages.admin_client_secret_note()}</p>
          </div>
          <Button
            hierarchy="secondary-gray"
            onPress={() => run(model.reload)}
            size="sm"
          >
            {messages.admin_refresh()}
          </Button>
        </div>

        <ClientCatalog
          onRetry={() => run(model.reload)}
          onSelect={(client) => run(model.openClient(client))}
          state={state}
        />
      </div>

      {drawer?.kind === "create" && ready ? (
        <CreateClientDrawer model={drawer.model} onClose={close} />
      ) : null}

      {drawer?.kind === "client" ? (
        <ClientDetailsDrawer model={drawer.model} onClose={close} />
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
        message={messages.admin_loading_oauth_body()}
        title={messages.admin_loading_oauth()}
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
        message={messages.admin_oauth_none_body()}
        title={messages.admin_oauth_none()}
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
        <table aria-label={messages.admin_section_oauth()} className="admin-data-table">
          <thead>
            <tr>
              <th scope="col">{messages.admin_column_client()}</th>
              <th scope="col">{messages.admin_column_type()}</th>
              <th scope="col">{messages.admin_column_status()}</th>
              <th scope="col">{messages.admin_column_redirects()}</th>
              <th scope="col">{messages.admin_column_created()}</th>
              <th aria-label={messages.admin_manage_client()} scope="col" />
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
                <td>
                  {client.confidential
                    ? messages.admin_confidential()
                    : messages.admin_public_pkce()}
                </td>
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
                    {messages.admin_manage()}
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
  model,
  onClose,
}: {
  model: CreateClientModel;
  onClose: () => void;
}) {
  const run = useAdminCommand();
  const state = useAdminState(model.state);
  const commandBusy = useAdminState(model.confirmation.state, confirmationBusy);
  const { clientType, created, name, redirectText, secret } = state;
  const { formReady } = createClientForm(state);

  if (secret) {
    return (
      <ClientSecretDrawer
        onClear={onClose}
        onCopy={() => run(model.copySecret)}
        shown={secret}
      />
    );
  }

  if (created) {
    return (
      <AdminDrawer
        eyebrow={messages.admin_section_oauth()}
        onClose={onClose}
        title={messages.admin_client_created()}
      >
        <section
          aria-label={messages.admin_created_public_region()}
          className="admin-command-section"
        >
          <Badge color="success" size="sm" type="pill-color">
            {messages.admin_badge_active()}
          </Badge>
          <div>
            <h3>{created.name}</h3>
            <p className="admin-drawer-note">{messages.admin_public_client_note()}</p>
          </div>
          <DetailList
            items={[
              { label: messages.admin_client_id(), value: created.id },
              { label: messages.admin_type(), value: messages.admin_public_pkce() },
            ]}
          />
          <div className="admin-command-actions">
            <Button onPress={onClose}>{messages.admin_done()}</Button>
          </div>
        </section>
      </AdminDrawer>
    );
  }

  return (
    <AdminDrawer
      eyebrow={messages.admin_section_oauth()}
      isDismissable={!commandBusy}
      onClose={onClose}
      title={messages.admin_new_oauth_client()}
    >
      <form
        className="admin-command-form"
        onSubmit={(event) => {
          event.preventDefault();
          run(model.review);
        }}
      >
        <InputField
          label={messages.admin_client_name()}
          maxLength={64}
          minLength={3}
          onChange={(event) => run(model.setField("name", event.target.value))}
          required
          value={name}
        />
        <NativeField
          hint={messages.admin_redirects_hint()}
          label={messages.admin_column_redirects()}
        >
          <textarea
            maxLength={4_096}
            onChange={(event) =>
              run(model.setField("redirectText", event.target.value))
            }
            required
            rows={5}
            value={redirectText}
          />
        </NativeField>
        <NativeField
          hint={messages.admin_client_type_hint()}
          label={messages.admin_client_type()}
        >
          <select
            onChange={(event) =>
              run(model.setClientType(event.target.value as OauthClientType))
            }
            value={clientType}
          >
            <option value="confidential">{messages.admin_confidential()}</option>
            <option value="public">{messages.admin_public_pkce()}</option>
          </select>
        </NativeField>
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={onClose}>
            {messages.admin_cancel()}
          </Button>
          <Button isDisabled={!formReady} type="submit">
            {messages.admin_review_command()}
          </Button>
        </div>
      </form>

      <AdminConfirmationDialog confirmation={model.confirmation} />
    </AdminDrawer>
  );
}

function ClientDetailsDrawer({
  model,
  onClose,
}: {
  model: ClientDetailsModel;
  onClose: () => void;
}) {
  const run = useAdminCommand();
  const { client, secret } = useAdminState(model.state);
  const commandBusy = useAdminState(model.confirmation.state, confirmationBusy);

  if (secret) {
    return (
      <ClientSecretDrawer
        onClear={() => run(model.clearSecret)}
        onCopy={() => run(model.copySecret)}
        shown={secret}
      />
    );
  }

  const status = clientStatus(client);

  return (
    <AdminDrawer
      eyebrow={messages.admin_section_oauth()}
      isDismissable={!commandBusy}
      onClose={onClose}
      title={messages.admin_manage_oauth_client()}
    >
      <div className="admin-drawer-summary">
        <div>
          <h3>{client.name}</h3>
          <p>
            {client.confidential
              ? messages.admin_confidential_client()
              : messages.admin_public_client()}
          </p>
        </div>
        <StatusBadge status={status} />
      </div>

      <DetailList
        items={[
          { label: messages.admin_client_id(), value: client.id },
          { label: messages.admin_created(), value: formatIso(client.created_at) },
          { label: messages.admin_disabled_at(), value: formatIso(client.disabled_at) },
        ]}
      />

      <section className="admin-drawer-section">
        <div className="admin-drawer-section-header">
          <div>
            <h3>{messages.admin_column_redirects()}</h3>
            <p>{messages.admin_redirects_note()}</p>
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
            <h3>{messages.admin_credentials_access()}</h3>
          </div>
        </div>
        <div className="admin-command-actions admin-command-actions-split">
          {client.confidential ? (
            <Button
              hierarchy="secondary-gray"
              onPress={() => run(model.review("rotate"))}
            >
              {messages.admin_rotate_secret()}
            </Button>
          ) : (
            <span />
          )}
          {client.disabled_at ? (
            <Button onPress={() => run(model.review("enable"))}>
              {messages.admin_enable_client()}
            </Button>
          ) : (
            <Button
              hierarchy="destructive"
              onPress={() => run(model.review("disable"))}
            >
              {messages.admin_disable_client()}
            </Button>
          )}
        </div>
      </section>

      <AdminConfirmationDialog confirmation={model.confirmation} />
    </AdminDrawer>
  );
}

function ClientSecretDrawer({
  onClear,
  onCopy,
  shown,
}: {
  onClear: () => void;
  onCopy: () => void;
  shown: ShownSecret;
}) {
  const { copied, secret } = shown;

  return (
    <AdminDrawer
      eyebrow={messages.admin_section_oauth()}
      isDismissable={false}
      onClose={onClear}
      title={
        secret.kind === "created"
          ? messages.admin_secret_created_title()
          : messages.admin_secret_rotated_title()
      }
    >
      <section
        aria-label={messages.admin_oauth_secret_region()}
        className="admin-secret-panel"
      >
        <Badge color="warning" size="sm" type="pill-color">
          {messages.admin_shown_once()}
        </Badge>
        <div>
          <h3>{secret.client.name}</h3>
          <p>{messages.admin_secret_body()}</p>
        </div>
        <code>{secret.value}</code>
        <DetailList
          items={[
            { label: messages.admin_client_id(), value: secret.client.id },
            { label: messages.admin_type(), value: messages.admin_confidential() },
          ]}
        />
        <div className="admin-command-actions">
          <Button hierarchy="secondary-gray" onPress={onCopy}>
            {copied ? messages.admin_copied() : messages.admin_copy_secret()}
          </Button>
          <Button onPress={onClear}>{messages.admin_done_and_clear()}</Button>
        </div>
      </section>
    </AdminDrawer>
  );
}

function clientStatus(client: CatalogOauthClient) {
  return client.disabled_at ? "disabled" : "active";
}

function redirectUriSummary(uris: ReadonlyArray<string>) {
  if (uris.length === 0) return "—";
  if (uris.length === 1) return uris[0];
  return `${uris[0]} +${uris.length - 1}`;
}

import { LoadingIndicator } from "@comma/ui";
import type { CommaLocale } from "@comma/i18n";
import { useCommaMessages } from "@comma/i18n/react";
import {
  Badge,
  Button,
  CreatedSecretPanel,
  Dialog,
  EditBigIcon,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  MenuTrigger,
  MoreHorizontalIcon,
  PlusIcon,
  TrashCanIcon,
} from "@comma/ui";
import { useState } from "react";
import type { CommaRouterApiKey, CommaRouterApiKeyCreated } from "../../api";
import { InlineTextEditor } from "../tasks/InlineTextEditor";

export type RouterApiKeyDraft = { name: string };

export interface RouterApiKeysPageProps {
  /** Id of the key (or "create") whose write is in flight. */
  busy: string | undefined;
  /** The key just minted, plaintext included, until the person dismisses it. */
  created: CommaRouterApiKeyCreated | undefined;
  error: string | undefined;
  keys: readonly CommaRouterApiKey[] | undefined;
  loading: boolean;
  locale: CommaLocale;
  onCreate: (draft: RouterApiKeyDraft) => void;
  onDelete: (keyId: string) => void;
  onDismissCreated: () => void;
  onRename: (keyId: string, name: string) => void;
  onRetry: () => void;
  onSetStatus: (keyId: string, status: "active" | "disabled") => void;
  workspaceId: string | undefined;
}

function formatDate(seconds: number | null | undefined, locale: CommaLocale): string {
  if (!seconds) return "—";
  return new Date(seconds * 1000).toLocaleDateString(locale, {
    month: "short",
    day: "numeric",
  });
}

/**
 * The `curl` a person pastes to try the key. The posting URL comes from the
 * server with the key: it is on the Salix host, not this app's API, and its
 * path names the Salix group id.
 */
export function routerApiKeyExample(created: CommaRouterApiKeyCreated): string {
  return [
    `curl -X POST ${created.post_message_url} \\`,
    `  -H 'Authorization: Bearer ${created.key}' \\`,
    "  -H 'Content-Type: application/json' \\",
    `  -d '{"text": "Hello from an external service", "source_message_id": "example-1"}'`,
  ].join("\n");
}

function CreatedKeyPanel({
  created,
  onDismiss,
}: {
  created: CommaRouterApiKeyCreated;
  onDismiss: () => void;
}) {
  const messages = useCommaMessages();
  return (
    <CreatedSecretPanel
      badge={messages.settings_inbound_api_shown_once()}
      copiedLabel={messages.common_copied()}
      copyLabel={messages.common_copy()}
      description={messages.settings_inbound_api_created_description()}
      doneLabel={messages.settings_inbound_api_done()}
      example={routerApiKeyExample(created)}
      label={messages.settings_inbound_api_created_title()}
      name={created.name}
      onDismiss={onDismiss}
      secret={created.key}
      testIds={{ root: "inbound-api-created", secret: "inbound-api-secret" }}
    />
  );
}

function KeyRow({
  busy,
  apiKey,
  locale,
  onDelete,
  onRename,
  onSetStatus,
}: {
  busy: boolean;
  apiKey: CommaRouterApiKey;
  locale: CommaLocale;
  onDelete: (keyId: string) => void;
  onRename: (keyId: string, name: string) => void;
  onSetStatus: (keyId: string, status: "active" | "disabled") => void;
}) {
  const messages = useCommaMessages();
  const [renameRequest, setRenameRequest] = useState(0);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const active = apiKey.status === "active";
  const actionsLabel = messages.settings_inbound_api_actions();

  return (
    <tr
      className="comma-task-labels-row"
      data-testid={`inbound-api-key-${apiKey.key_id}`}
    >
      <td className="comma-task-labels-cell">
        <InlineTextEditor
          disabled={busy}
          editRequest={renameRequest}
          label={messages.settings_inbound_api_rename()}
          onCommit={(name) => name && onRename(apiKey.key_id, name)}
          placeholder={messages.settings_inbound_api_name_placeholder()}
          value={apiKey.name}
        />
      </td>
      <td className="comma-task-labels-cell">
        <code className="text-xs text-secondary">{apiKey.prefix}…</code>
      </td>
      <td className="comma-task-labels-cell">
        <Badge color={active ? "success" : "gray"} size="sm" type="pill-color">
          {active
            ? messages.settings_inbound_api_status_active()
            : messages.settings_inbound_api_status_disabled()}
        </Badge>
      </td>
      <td className="comma-task-labels-cell comma-task-labels-num">
        {formatDate(apiKey.created_at, locale)}
      </td>
      <td className="comma-task-labels-cell comma-task-labels-num">
        {formatDate(apiKey.last_used_at, locale)}
      </td>
      <td className="comma-task-labels-cell comma-task-labels-num">
        {formatDate(apiKey.expires_at, locale)}
      </td>
      <td className="comma-task-labels-cell comma-task-labels-actions">
        <MenuTrigger>
          <Button
            aria-label={actionsLabel}
            hierarchy="tertiary-gray"
            iconLeading={<MoreHorizontalIcon />}
            iconOnly
            isDisabled={busy}
            size="sm"
          />
          <MenuPopover placement="bottom end">
            <Menu
              aria-label={actionsLabel}
              onAction={(action) => {
                if (action === "rename") setRenameRequest((request) => request + 1);
                else if (action === "toggle")
                  onSetStatus(apiKey.key_id, active ? "disabled" : "active");
                else if (action === "delete") setConfirmDelete(true);
              }}
            >
              <MenuItem icon={<EditBigIcon />} id="rename">
                {messages.settings_inbound_api_rename()}
              </MenuItem>
              <MenuItem id="toggle">
                {active
                  ? messages.settings_inbound_api_disable()
                  : messages.settings_inbound_api_enable()}
              </MenuItem>
              <MenuSeparator />
              <MenuItem icon={<TrashCanIcon />} id="delete" tone="destructive">
                {messages.settings_inbound_api_delete()}
              </MenuItem>
            </Menu>
          </MenuPopover>
        </MenuTrigger>
        {confirmDelete ? (
          <Dialog
            actions={[
              {
                label: messages.settings_profile_cancel(),
                hierarchy: "secondary-gray",
                onPress: () => setConfirmDelete(false),
              },
              {
                label: messages.settings_inbound_api_delete(),
                hierarchy: "destructive",
                onPress: () => {
                  setConfirmDelete(false);
                  onDelete(apiKey.key_id);
                },
              },
            ]}
            description={messages.settings_inbound_api_delete_description({
              name: apiKey.name,
            })}
            isDismissable
            isOpen
            onOpenChange={setConfirmDelete}
            title={messages.settings_inbound_api_delete_title()}
          />
        ) : null}
      </td>
    </tr>
  );
}

export function RouterApiKeysPage({
  busy,
  created,
  error,
  keys,
  loading,
  locale,
  onCreate,
  onDelete,
  onDismissCreated,
  onRename,
  onRetry,
  onSetStatus,
  workspaceId,
}: RouterApiKeysPageProps) {
  const messages = useCommaMessages();
  const [draftName, setDraftName] = useState<string>();
  const creating = draftName !== undefined;
  const name = draftName?.trim() ?? "";

  const commit = () => {
    if (!name) return;
    onCreate({ name });
    setDraftName(undefined);
  };

  const noKeys = !loading && !error && keys !== undefined && keys.length === 0;

  return (
    <div className="comma-task-labels-page" data-testid="inbound-api-settings">
      <header className="flex flex-col gap-xs">
        <h1 className="comma-task-labels-title">
          {messages.settings_inbound_api_title()}
        </h1>
        <p className="m-0 text-sm text-tertiary">
          {messages.settings_inbound_api_description()}
        </p>
      </header>

      {created ? (
        <CreatedKeyPanel created={created} onDismiss={onDismissCreated} />
      ) : null}

      <div className="comma-task-labels-toolbar">
        <div className="ml-auto">
          <Button
            className="h-auto px-lg py-xs"
            hierarchy="primary"
            iconLeading={<PlusIcon />}
            isDisabled={busy !== undefined || creating || !keys || !workspaceId}
            onPress={() => setDraftName("")}
            size="sm"
          >
            {messages.settings_inbound_api_new()}
          </Button>
        </div>
      </div>

      {creating ? (
        <Dialog
          actions={[
            {
              label: messages.settings_profile_cancel(),
              hierarchy: "secondary-gray",
              onPress: () => setDraftName(undefined),
            },
            {
              label: messages.settings_inbound_api_create(),
              hierarchy: "primary",
              disabled: !name,
              onPress: commit,
            },
          ]}
          description={messages.settings_inbound_api_new_description()}
          input={{
            autoFocus: true,
            label: messages.settings_inbound_api_name_label(),
            maxLength: 80,
            name: "name",
            onChange: (event) => setDraftName(event.target.value),
            placeholder: messages.settings_inbound_api_name_placeholder(),
            value: draftName ?? "",
          }}
          isDismissable
          isOpen
          onOpenChange={(open) => {
            if (!open) setDraftName(undefined);
          }}
          title={messages.settings_inbound_api_new()}
          variant="input"
        />
      ) : null}

      {noKeys ? (
        <div className="comma-task-labels-empty" data-testid="inbound-api-none">
          <div className="comma-task-labels-state-stack">
            {messages.settings_inbound_api_none()}
          </div>
        </div>
      ) : (
        <table className="comma-task-labels-table">
          <thead>
            <tr className="comma-task-labels-head">
              <th className="comma-task-labels-cell" scope="col">
                {messages.settings_inbound_api_column_name()}
              </th>
              <th className="comma-task-labels-cell" scope="col">
                {messages.settings_inbound_api_column_prefix()}
              </th>
              <th className="comma-task-labels-cell" scope="col">
                {messages.settings_inbound_api_column_status()}
              </th>
              <th className="comma-task-labels-cell comma-task-labels-num" scope="col">
                {messages.settings_inbound_api_column_created()}
              </th>
              <th className="comma-task-labels-cell comma-task-labels-num" scope="col">
                {messages.settings_inbound_api_column_last_used()}
              </th>
              <th className="comma-task-labels-cell comma-task-labels-num" scope="col">
                {messages.settings_inbound_api_column_expires()}
              </th>
              <th
                className="comma-task-labels-cell comma-task-labels-actions"
                scope="col"
              >
                <span className="app-sr-only">
                  {messages.settings_inbound_api_actions()}
                </span>
              </th>
            </tr>
          </thead>
          <tbody>
            {error ? (
              <tr>
                <td
                  className="comma-task-labels-cell comma-task-labels-state"
                  colSpan={7}
                >
                  <div
                    aria-live="polite"
                    className="comma-task-labels-state-stack"
                    data-testid="inbound-api-error"
                  >
                    {error}
                    <Button
                      className="h-7 px-lg"
                      hierarchy="secondary-gray"
                      onPress={onRetry}
                      size="sm"
                    >
                      {messages.common_retry()}
                    </Button>
                  </div>
                </td>
              </tr>
            ) : null}

            {loading && !error ? (
              <tr>
                <td
                  className="comma-task-labels-cell comma-task-labels-state"
                  colSpan={7}
                >
                  <span data-testid="inbound-api-loading">
                    <LoadingIndicator label={messages.settings_inbound_api_loading()} />
                  </span>
                </td>
              </tr>
            ) : null}

            {(keys ?? []).map((apiKey) => (
              <KeyRow
                apiKey={apiKey}
                busy={busy === apiKey.key_id}
                key={apiKey.key_id}
                locale={locale}
                onDelete={onDelete}
                onRename={onRename}
                onSetStatus={onSetStatus}
              />
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

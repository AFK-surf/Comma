import { useCommaMessages } from "@comma/i18n/react";
import {
  Button,
  Collapse,
  CollapseContent,
  LoaderIcon,
  PluginArtwork,
  PluginDetailSection,
  type PluginDefinition,
} from "@comma/ui";
import { useState } from "react";
import type { CommaPlugin, CommaPluginAccountConfirmation } from "../../api";
import { PluginBrandArtwork } from "./PluginBrandArtwork";
import type {
  PluginConnectionSource,
  PluginPersonalSources as PersonalSourcesState,
} from "./usePluginPersonalSources";

// A Composio toolkit is a product of its own inside the plugin, such as Gmail in
// Google Workspace. A managed OAuth source reads the plugin's own product.
const toolkitNames: Readonly<Record<string, string>> = {
  gmail: "Gmail",
  googlecalendar: "Google Calendar",
  googledrive: "Google Drive",
  slack: "Slack",
};

/** A 28px row action whose hit area reaches 42px without changing the row. */
const rowActionClassName =
  "relative h-7 px-lg py-xs after:absolute after:inset-x-0 after:-inset-y-md";

// An MCP OAuth grant lets the plugin's MCP tools act. Comma does not read your
// work through it, so it is not a personal source.
const isMcpGrant = (source: PluginConnectionSource) =>
  source.kind === "native_mcp_oauth";

export function PluginPersonalSources({
  plugin,
  personalSources,
  reauthorizingConnectionId,
  onReauthorize,
}: {
  plugin: Pick<CommaPlugin, "name" | "brand">;
  personalSources: PersonalSourcesState;
  reauthorizingConnectionId: string | undefined;
  onReauthorize: (connectionId: string) => void;
}) {
  const messages = useCommaMessages();
  const { error, retry } = personalSources;
  const sources = personalSources.sources?.filter((source) => !isMcpGrant(source));

  // The section appears with its first read, never as an empty heading.
  if (!sources?.length && !error) return null;

  return (
    <PluginDetailSection title={messages.plugins_personal_sources()}>
      <p className="m-0 px-md text-pretty text-sm text-quaternary">
        {messages.plugins_personal_sources_description()}
      </p>
      {error ? (
        <div className="flex items-center gap-sm px-md" role="alert">
          <span className="text-sm text-error-primary">{error}</span>
          <Button
            className="h-7 px-lg py-xs"
            hierarchy="tertiary-gray"
            onPress={retry}
            size="sm"
          >
            {messages.common_retry()}
          </Button>
        </div>
      ) : null}
      {sources?.length ? (
        <ul className="m-0 flex list-none flex-col gap-xs p-0">
          {sources.map((source) => (
            <PersonalSourceRow
              key={source.connectionId}
              name={sourceName(source, plugin.name)}
              onReauthorize={onReauthorize}
              personalSources={personalSources}
              pluginBrand={plugin.brand}
              reauthorizing={reauthorizingConnectionId === source.connectionId}
              source={source}
            />
          ))}
        </ul>
      ) : null}
    </PluginDetailSection>
  );
}

/** Puts each MCP grant's reconnect action on the MCPs it authorizes. */
export function withMcpGrants(
  definition: PluginDefinition,
  {
    pluginName,
    personalSources,
    reauthorizingConnectionId,
    onReauthorize,
  }: {
    pluginName: string;
    personalSources: PersonalSourcesState;
    reauthorizingConnectionId: string | undefined;
    onReauthorize: (connectionId: string) => void;
  }
): PluginDefinition {
  const grants = (personalSources.sources ?? []).filter(isMcpGrant);
  if (!definition.mcps || grants.length === 0) return definition;
  return {
    ...definition,
    mcps: definition.mcps.map((resource) => {
      const grant = grants.find((source) => source.mcpIds?.includes(resource.id));
      if (!grant) return resource;
      return {
        ...resource,
        trailingContent: (
          <McpGrantReconnect
            disabled={personalSources.pending !== undefined}
            name={sourceName(grant, pluginName)}
            onPress={() => onReauthorize(grant.connectionId)}
            reconnecting={reauthorizingConnectionId === grant.connectionId}
          />
        ),
      };
    }),
  };
}

function McpGrantReconnect({
  name,
  disabled,
  reconnecting,
  onPress,
}: {
  name: string;
  disabled: boolean;
  reconnecting: boolean;
  onPress: () => void;
}) {
  const messages = useCommaMessages();
  return (
    <Button
      aria-label={messages.plugins_reconnect_named({ name })}
      // The negative margin keeps the MCP row's height with or without it.
      className={`-my-xxs ${rowActionClassName}`}
      hierarchy="tertiary-gray"
      iconLeading={reconnecting ? <LoaderIcon className="animate-spin" /> : undefined}
      isDisabled={disabled || reconnecting}
      onPress={onPress}
      size="sm"
    >
      {messages.plugins_reconnect()}
    </Button>
  );
}

function PersonalSourceRow({
  source,
  name,
  pluginBrand,
  personalSources,
  reauthorizing,
  onReauthorize,
}: {
  source: PluginConnectionSource;
  name: string;
  pluginBrand: string | null | undefined;
  personalSources: PersonalSourcesState;
  reauthorizing: boolean;
  onReauthorize: (connectionId: string) => void;
}) {
  const messages = useCommaMessages();
  const { confirmation, pending, prepare, confirm, cancel } = personalSources;
  const needsAuthorization = source.state === "needs_authorization";
  // The grant exists but lacks a scope the plugin needs now, or was revoked.
  const needsReauthorization = source.state === "needs_reauthorization";
  const activeConfirmation =
    confirmation?.toolkit === source.toolkit ? confirmation : undefined;
  const candidates =
    source.kind === "composio"
      ? source.candidates.filter(
          (candidate) => candidate.id !== source.selectedAccountId
        )
      : [];
  // Each connected account to choose sits with Reconnect. Beside the account in
  // use it is a switch. An account ID means nothing to its owner: its ending
  // appears only to tell accounts apart.
  const candidateLabel = (accountId: string) => {
    const suffix = accountId.slice(-4);
    if (source.state === "ready")
      return messages.plugins_personal_source_switch_account({ suffix });
    return candidates.length > 1
      ? messages.plugins_personal_source_check_account_ending({ suffix })
      : messages.plugins_personal_source_check_account();
  };

  return (
    <li className="grid grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-x-md rounded-xl px-md py-sm">
      <PluginArtwork
        icon={
          <PluginBrandArtwork
            brand={source.kind === "composio" ? source.toolkit : pluginBrand}
            name={name}
          />
        }
        size="sm"
      />
      <span className="flex min-w-0 flex-col gap-xxs text-sm">
        <span className="truncate text-primary">{name}</span>
        <span className="text-pretty text-quaternary">
          {source.state === "ready"
            ? messages.plugins_personal_source_ready()
            : source.state === "needs_confirmation"
              ? messages.plugins_personal_source_needs_confirmation()
              : needsReauthorization
                ? messages.plugins_personal_source_needs_reauthorization()
                : messages.plugins_personal_source_needs_authorization()}
        </span>
      </span>
      <div className="flex items-center gap-xs">
        {candidates.map((candidate) => (
          <Button
            className={rowActionClassName}
            hierarchy="secondary-gray"
            iconLeading={
              pending?.type === "prepare" && pending.accountId === candidate.id ? (
                <LoaderIcon className="animate-spin" />
              ) : undefined
            }
            isDisabled={pending !== undefined}
            key={candidate.id}
            onPress={() => void prepare(source, candidate.id)}
            size="sm"
          >
            {candidateLabel(candidate.id)}
          </Button>
        ))}
        <Button
          aria-label={
            needsAuthorization
              ? messages.plugins_connect_named({ name })
              : messages.plugins_reconnect_named({ name })
          }
          className={rowActionClassName}
          hierarchy={
            needsAuthorization || needsReauthorization
              ? "secondary-gray"
              : "tertiary-gray"
          }
          iconLeading={
            reauthorizing ? <LoaderIcon className="animate-spin" /> : undefined
          }
          isDisabled={pending !== undefined || reauthorizing}
          onPress={() => {
            cancel();
            onReauthorize(source.connectionId);
          }}
          size="sm"
        >
          {needsAuthorization
            ? messages.plugins_connect()
            : messages.plugins_reconnect()}
        </Button>
      </div>
      {source.kind === "composio" ? (
        <div className="col-span-2 col-start-2">
          <ConfirmationPanel
            confirmation={activeConfirmation}
            confirming={pending?.type === "confirm"}
            disabled={pending !== undefined}
            onCancel={cancel}
            onConfirm={() => void confirm()}
          />
        </div>
      ) : null}
    </li>
  );
}

function ConfirmationPanel({
  confirmation,
  confirming,
  disabled,
  onConfirm,
  onCancel,
}: {
  confirmation: CommaPluginAccountConfirmation | undefined;
  confirming: boolean;
  disabled: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const messages = useCommaMessages();
  // The account stays on screen while the panel closes.
  const [shown, setShown] = useState(confirmation);
  if (confirmation && confirmation !== shown) setShown(confirmation);

  return (
    <Collapse open={confirmation !== undefined}>
      <CollapseContent className="pt-sm">
        {shown ? (
          // Buttons keep radius-md inside padding-md, so the panel is 2xl.
          <div className="flex flex-col gap-md rounded-2xl bg-secondary p-md">
            <p className="m-0 text-pretty text-sm text-primary">
              {messages.plugins_personal_source_confirmation_note({
                identity: shown.identity,
              })}
            </p>
            <div className="flex gap-sm">
              <Button
                className="h-7 px-lg py-xs"
                hierarchy="primary"
                iconLeading={
                  confirming ? <LoaderIcon className="animate-spin" /> : undefined
                }
                isDisabled={disabled}
                onPress={onConfirm}
                size="sm"
              >
                {messages.plugins_personal_source_confirm()}
              </Button>
              <Button
                className="h-7 px-lg py-xs"
                hierarchy="tertiary-gray"
                isDisabled={disabled}
                onPress={onCancel}
                size="sm"
              >
                {messages.plugins_personal_source_cancel()}
              </Button>
            </div>
          </div>
        ) : null}
      </CollapseContent>
    </Collapse>
  );
}

function sourceName(source: PluginConnectionSource, pluginName: string) {
  switch (source.kind) {
    case "composio":
      return toolkitNames[source.toolkit] ?? pluginName;
    case "native_mcp_oauth":
      return `${pluginName} MCP`;
    case "managed_oauth":
      return pluginName;
  }
}

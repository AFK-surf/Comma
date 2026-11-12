import { useCall, useTopic, type McpServer } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import { CubeIcon } from "@comma/ui/components/icons";
import { InputField } from "@comma/ui/components/input";
import { PluginDetailSection, PluginListItem } from "@comma/ui/components/plugins";
import { toast } from "@comma/ui/components/toast";
import { useState } from "react";
import { openNativePlatformExternalUrl } from "../../nativePlatformActions";

/** What a search on the Plugins page finds this section by. */
export const MCP_SERVER_KEYWORDS = ["MCP", "server", "custom", "服务器", "自定义"];

/**
 * The MCP servers this workspace connected by address (the core's `mcpServers`),
 * however they were added, and the way to add one. A sign-in opens in the browser;
 * the core follows it and the row turns connected by itself.
 */
export function McpServers({ workspace }: { workspace: string }) {
  const call = useCall();
  const messages = useCommaMessages();
  const { value } = useTopic({ topic: "mcpServers", workspace });
  const [adding, setAdding] = useState(false);
  const [pending, setPending] = useState<string>();

  const connect = (server: McpServer) => {
    setPending(server.id);
    void call("mcpServer.connect", { workspace, server: server.id })
      .then(async (answer) => {
        if (answer.authorizationUrl)
          await openNativePlatformExternalUrl(answer.authorizationUrl);
      })
      .catch(() =>
        toast.error(messages.plugins_mcp_reconnect_failed({ name: server.name }))
      )
      .finally(() => setPending(undefined));
  };

  const remove = (server: McpServer) => {
    setPending(server.id);
    void call("mcpServer.remove", { workspace, server: server.id })
      .catch(() =>
        toast.error(messages.plugins_mcp_remove_failed({ name: server.name }))
      )
      .finally(() => setPending(undefined));
  };

  const status = (server: McpServer) => {
    switch (server.status) {
      case "connected":
        return messages.plugins_mcp_status_connected({ count: server.tools });
      case "needs_authorization":
        return messages.plugins_mcp_status_needs_authorization();
      case "failed":
        return messages.plugins_mcp_status_failed();
    }
  };

  return (
    <PluginDetailSection
      title={messages.plugins_mcp_servers()}
      action={
        <Button
          className="h-7 px-lg py-xs"
          hierarchy="tertiary-gray"
          onPress={() => setAdding(true)}
          size="sm"
        >
          {messages.plugins_mcp_add()}
        </Button>
      }
    >
      {value?.error === "load_failed" && !value.servers ? (
        <output className="mx-md block rounded-lg bg-secondary px-md py-sm text-sm text-secondary">
          {messages.plugins_mcp_load_failed()}
        </output>
      ) : null}
      {value?.servers?.length ? (
        <ul className="m-0 flex list-none flex-col gap-xs p-0">
          {value.servers.map((server) => (
            <li key={server.id}>
              <PluginListItem
                plugin={{
                  icon: <CubeIcon className="text-fg-tertiary" />,
                  id: server.id,
                  name: server.name,
                  summary: status(server),
                }}
                trailingContent={
                  <span className="flex shrink-0 items-center gap-xs">
                    {server.status === "connected" ? null : (
                      <Button
                        className="h-7 px-lg py-xs"
                        hierarchy="secondary-gray"
                        isDisabled={pending !== undefined}
                        onPress={() => connect(server)}
                        size="sm"
                      >
                        {server.status === "needs_authorization"
                          ? messages.plugins_mcp_sign_in()
                          : messages.plugins_mcp_reconnect()}
                      </Button>
                    )}
                    <Button
                      aria-label={messages.plugins_mcp_remove_named({
                        name: server.name,
                      })}
                      className="h-7 px-lg py-xs"
                      hierarchy="tertiary-gray"
                      isDisabled={pending !== undefined}
                      onPress={() => remove(server)}
                      size="sm"
                    >
                      {messages.plugins_mcp_remove()}
                    </Button>
                  </span>
                }
              />
            </li>
          ))}
        </ul>
      ) : null}
      {adding ? (
        <AddMcpServerDialog onClose={() => setAdding(false)} workspace={workspace} />
      ) : null}
    </PluginDetailSection>
  );
}

function AddMcpServerDialog({
  onClose,
  workspace,
}: {
  onClose(): void;
  workspace: string;
}) {
  const call = useCall();
  const messages = useCommaMessages();
  const [url, setUrl] = useState("");
  const [name, setName] = useState("");
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string>();

  const failure = (code: unknown) => {
    switch (code) {
      case "invalid_mcp_url":
        return messages.plugins_mcp_error_invalid_url();
      case "mcp_server_exists":
        return messages.plugins_mcp_error_exists();
      case "mcp_server_unreachable":
        return messages.plugins_mcp_error_unreachable();
      case "mcp_server_authorization_unavailable":
        return messages.plugins_mcp_error_authorization_unavailable();
      default:
        return messages.plugins_mcp_error_other();
    }
  };

  const submit = () => {
    setPending(true);
    setError(undefined);
    void call("mcpServer.add", {
      workspace,
      url: url.trim(),
      ...(name.trim() ? { name: name.trim() } : {}),
    })
      .then(async (answer) => {
        if (answer.authorizationUrl)
          await openNativePlatformExternalUrl(answer.authorizationUrl);
        onClose();
      })
      .catch((reason: { code?: unknown }) => {
        setError(failure(reason.code));
        setPending(false);
      });
  };

  return (
    <Dialog
      isOpen
      isDismissable={!pending}
      onOpenChange={(open) => {
        if (!open && !pending) onClose();
      }}
      title={messages.plugins_mcp_add()}
      description={messages.plugins_mcp_add_description()}
      actions={[
        {
          label: messages.plugins_personal_source_cancel(),
          hierarchy: "secondary-gray",
          disabled: pending,
          onPress: onClose,
        },
        {
          label: pending
            ? messages.plugins_mcp_connecting()
            : messages.plugins_mcp_connect(),
          hierarchy: "primary",
          disabled: pending || url.trim() === "",
          onPress: submit,
        },
      ]}
    >
      <div className="flex w-full flex-col gap-md" aria-busy={pending}>
        <InputField
          autoComplete="off"
          className="w-full"
          disabled={pending}
          label={messages.plugins_mcp_url()}
          onChange={(event) => setUrl(event.target.value)}
          placeholder="https://example.com/mcp"
          type="url"
          value={url}
        />
        <InputField
          autoComplete="off"
          className="w-full"
          disabled={pending}
          label={messages.plugins_mcp_name()}
          onChange={(event) => setName(event.target.value)}
          value={name}
        />
        {error ? (
          <p className="m-0 text-sm text-error-primary" role="alert">
            {error}
          </p>
        ) : null}
      </div>
    </Dialog>
  );
}

import {
  useCall,
  useTopic,
  type PluginAccountConfirmation,
  type PluginSource,
  type PluginSourcesValue,
} from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { useEffect } from "react";

export type PluginConnectionSource = PluginSource;

export type PluginPersonalSourcesPending = NonNullable<PluginSourcesValue["pending"]>;

export interface PluginPersonalSources {
  /** Every connection the plugin reports; undefined until the first read. */
  sources: PluginConnectionSource[] | undefined;
  error: string | undefined;
  confirmation: PluginAccountConfirmation | undefined;
  pending: PluginPersonalSourcesPending | undefined;
  retry: () => void;
  prepare: (source: PluginConnectionSource, accountId: string) => Promise<void>;
  confirm: () => Promise<void>;
  cancel: () => void;
}

/**
 * The owner's connections for one installed plugin, as the client core keeps
 * them (`pluginSources`). A confirmation left open when the page goes is let go.
 */
export function usePluginPersonalSources({
  workspaceId,
  pluginId,
}: {
  workspaceId: string | undefined;
  pluginId: string | undefined;
}): PluginPersonalSources {
  const messages = useCommaMessages();
  const call = useCall();
  const target =
    workspaceId && pluginId ? { plugin: pluginId, workspace: workspaceId } : null;
  const { value } = useTopic(target ? { topic: "pluginSources", ...target } : null);

  useEffect(() => {
    if (!workspaceId || !pluginId) return undefined;
    return () =>
      void call("plugin.sources.cancel", {
        plugin: pluginId,
        workspace: workspaceId,
      }).catch(() => undefined);
  }, [call, pluginId, workspaceId]);

  const error =
    value?.error === "load_failed"
      ? messages.plugins_personal_source_load_failed()
      : value?.error === "not_personal"
        ? messages.plugins_personal_source_not_personal()
        : value?.error === "confirm_failed"
          ? messages.plugins_personal_source_confirm_failed()
          : undefined;

  return {
    sources: value?.sources ?? undefined,
    error,
    confirmation: value?.confirmation ?? undefined,
    pending: value?.pending ?? undefined,
    retry: () => {
      if (target) void call("plugin.sources.refresh", target).catch(() => undefined);
    },
    prepare: async (source, accountId) => {
      if (target)
        await call("plugin.sources.prepare", {
          ...target,
          account: accountId,
          toolkit: source.toolkit,
        }).catch(() => undefined);
    },
    confirm: async () => {
      if (target) await call("plugin.sources.confirm", target).catch(() => undefined);
    },
    cancel: () => {
      if (target) void call("plugin.sources.cancel", target).catch(() => undefined);
    },
  };
}

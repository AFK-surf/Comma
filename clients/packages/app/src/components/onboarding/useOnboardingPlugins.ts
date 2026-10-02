import { useCallback, useEffect, useState } from "react";
import type { CommaApiClient, CommaPlugin } from "../../api";
import { usePluginInstall } from "../plugins/PluginInstallProvider";
import type { OnboardingWorkspace } from "./useOnboardingWorkspace";

export type OnboardingPluginConnection = "idle" | "connecting" | "connected";

export type OnboardingPluginRow = {
  id: string;
  name: string;
  summary: string;
  brand: string | null | undefined;
  connection: OnboardingPluginConnection;
};

export type OnboardingPluginList =
  | { status: "preparing"; unreachable?: boolean }
  | { status: "loading" }
  | { status: "ready"; rows: OnboardingPluginRow[] }
  | { status: "unavailable" };

// The integrations most people reach for first; the rest follow in catalog order.
const preferredPluginOrder = [
  "google",
  "github",
  "notion",
  "slack",
  "linear",
  "feishu",
];

/**
 * How many apps the list expects before the catalog has loaded: the
 * integrations most people connect first, which every workspace offers.
 */
export const onboardingPreferredPluginCount = preferredPluginOrder.length;

/** A catalog request with no answer by then is given up and tried again. */
const catalogTimeoutMs = 20_000;
const catalogRetryMs = 10_000;

type Catalog =
  | { workspaceId: string; plugins: CommaPlugin[] }
  | { workspaceId: string; failed: true };

/**
 * The workspace's integrations for the plugins step, with each row's
 * connection read from the window's one plugin authorization
 * (`PluginInstallProvider`), so an authorization finished in the browser
 * lands here as it does on the Plugins page.
 */
export function useOnboardingPlugins({
  api,
  workspace,
}: {
  api: CommaApiClient;
  workspace: OnboardingWorkspace;
}): { list: OnboardingPluginList; connect: (pluginId: string) => void } {
  const installation = usePluginInstall();
  const workspaceId = workspace.status === "ready" ? workspace.workspaceId : undefined;
  const [catalog, setCatalog] = useState<Catalog>();

  // Bound: one request in flight per onboarding, each given up after
  // `catalogTimeoutMs`; a failed or abandoned one says so and is tried again
  // every `catalogRetryMs` until the catalog arrives or the onboarding ends.
  useEffect(() => {
    if (!workspaceId) return undefined;
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const attempt = () => {
      const request = new AbortController();
      const abandon = setTimeout(() => request.abort(), catalogTimeoutMs);
      const stop = () => request.abort();
      controller.signal.addEventListener("abort", stop);
      api
        .listWorkspacePlugins(workspaceId, { signal: request.signal })
        .then(
          (plugins) => {
            if (!controller.signal.aborted) setCatalog({ workspaceId, plugins });
          },
          () => {
            if (controller.signal.aborted) return;
            setCatalog((current) =>
              current?.workspaceId === workspaceId && "plugins" in current
                ? current
                : { workspaceId, failed: true }
            );
            timer = setTimeout(attempt, catalogRetryMs);
          }
        )
        .finally(() => {
          clearTimeout(abandon);
          controller.signal.removeEventListener("abort", stop);
        });
    };
    attempt();
    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [api, workspaceId]);

  // Every install answer carries the plugin as it now stands; merge it the way
  // the Plugins page does, so a finished authorization shows as Connected.
  const result = installation.result;
  useEffect(() => {
    if (!result) return;
    setCatalog((current) =>
      current && "plugins" in current && current.workspaceId === result.workspaceId
        ? {
            ...current,
            plugins: current.plugins.map((plugin) =>
              plugin.id === result.plugin.id ? result.plugin : plugin
            ),
          }
        : current
    );
  }, [result]);

  const { install, pending } = installation;
  const connect = useCallback(
    (pluginId: string) => {
      if (workspaceId) void install({ origin: "onboarding", pluginId, workspaceId });
    },
    [install, workspaceId]
  );

  if (workspace.status === "unavailable") {
    return { list: { status: "unavailable" }, connect };
  }
  if (!workspaceId) {
    return {
      list: {
        status: "preparing",
        ...(workspace.status === "preparing" && workspace.unreachable
          ? { unreachable: true }
          : {}),
      },
      connect,
    };
  }
  if (catalog?.workspaceId !== workspaceId)
    return { list: { status: "loading" }, connect };
  if ("failed" in catalog) return { list: { status: "unavailable" }, connect };

  // A request in flight, or an answer still waiting on the browser, is the
  // one authorization this window runs.
  const connectingId =
    pending?.workspaceId === workspaceId
      ? pending.pluginId
      : result?.workspaceId === workspaceId && !result.plugin.installed
        ? result.pluginId
        : undefined;
  const rows = orderPlugins(catalog.plugins.filter(isIntegration)).map(
    (plugin): OnboardingPluginRow => ({
      brand: plugin.brand,
      connection: plugin.installed
        ? "connected"
        : plugin.id === connectingId
          ? "connecting"
          : "idle",
      id: plugin.id,
      name: plugin.name,
      summary: plugin.summary,
    })
  );
  return { list: { status: "ready", rows }, connect };
}

function isIntegration(plugin: CommaPlugin) {
  const category = plugin.category.trim();
  return !plugin.locked && (category === "" || category === "Integrations");
}

function orderPlugins(plugins: readonly CommaPlugin[]) {
  const rank = (plugin: CommaPlugin) => {
    const index = preferredPluginOrder.indexOf(plugin.id);
    return index === -1 ? preferredPluginOrder.length : index;
  };
  // Sorting is stable, so the rest keep the catalog's own order.
  return plugins.toSorted((left, right) => rank(left) - rank(right));
}

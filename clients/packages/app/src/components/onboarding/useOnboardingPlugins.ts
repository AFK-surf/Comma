import {
  useTopic,
  type OnboardingPluginConnection,
  type OnboardingPluginList,
  type OnboardingPluginRow,
} from "@comma/core-client";
import { useCallback } from "react";
import { usePluginInstall } from "../plugins/pluginInstall";
import type { OnboardingWorkspace } from "./useOnboardingWorkspace";

export type { OnboardingPluginConnection, OnboardingPluginList, OnboardingPluginRow };

/**
 * How many apps the list expects before the catalog has loaded: the
 * integrations most people connect first, which every workspace offers.
 */
export const onboardingPreferredPluginCount = 6;

/**
 * The workspace's integrations for the apps step, as the client core lists
 * them (`onboardingApps`), each row's connection as the core's install of it
 * stands, so an authorization finished in the browser lands here as it does on
 * the Plugins page.
 */
export function useOnboardingPlugins({
  workspace,
}: {
  workspace: OnboardingWorkspace;
}): {
  list: OnboardingPluginList;
  connect: (pluginId: string) => void;
} {
  const { install } = usePluginInstall();
  const { value = { status: "preparing" } } = useTopic({ topic: "onboardingApps" });
  const workspaceId = workspace.status === "ready" ? workspace.workspaceId : undefined;
  const connect = useCallback(
    (pluginId: string) => {
      if (workspaceId) void install({ origin: "onboarding", pluginId, workspaceId });
    },
    [install, workspaceId]
  );
  return { list: value, connect };
}

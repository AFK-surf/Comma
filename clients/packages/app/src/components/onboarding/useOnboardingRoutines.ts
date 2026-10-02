import { useCallback, useMemo, useRef } from "react";
import type { CommaApiClient } from "../../api";
import type { OnboardingItemResult } from "./onboardingSetup";
import type { OnboardingWorkspace } from "./useOnboardingWorkspace";

/**
 * Starts the account's Routines in the background once the user is past the
 * onboarding's apps step with at least one app connected: the step answered
 * (`answered`), or Skip setup pressed (`skipped`). Home then has them, or has
 * them generating, when the onboarding ends.
 *
 * Reading the Routines creates them (on this device's timezone, which only
 * their creation records); the server then finds every connected
 * app at once and generates the first briefing by itself, and an app whose
 * connection completes later starts a fresh one. Reading only once the step
 * is over, rather than on each connection, makes that one run: before the
 * Routines exist a connection starts nothing, and after, each one replaces
 * the run in progress. With no app connected, nothing is read: Home creates
 * the Routines as it always does.
 */
export function useOnboardingRoutines({
  api,
  connected,
  workspace,
}: {
  api: Pick<CommaApiClient, "getRecommendations">;
  /** At least one app is connected now. */
  connected: boolean;
  workspace: OnboardingWorkspace;
}) {
  const started = useRef(false);
  const start = useCallback(() => {
    if (workspace.status !== "ready" || started.current) return;
    started.current = true;
    api
      .getRecommendations(workspace.workspaceId, {
        timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      })
      .catch((error: unknown) => {
        // Home reads them again as it opens.
        console.warn("[onboarding] Routines did not start", error);
      });
  }, [api, workspace]);

  return useMemo(
    () => ({
      answered: (result: OnboardingItemResult) => {
        if (result.item === "apps" && result.connected.length > 0) start();
      },
      skipped: () => {
        if (connected) start();
      },
    }),
    [connected, start]
  );
}

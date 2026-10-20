import { useTopic, type OnboardingWorkspace } from "@comma/core-client";
import { useEffect } from "react";
import { useSelectWorkspace } from "../activeWorkspace";

export type { OnboardingWorkspace };

/**
 * The account's default workspace while it is provisioned, as the client core
 * follows it (`onboardingWorkspace`): every workspace-scoped call the
 * onboarding makes answers `workspace_provisioning` until it is ready.
 */
export function useOnboardingWorkspace(): OnboardingWorkspace {
  const { value = { status: "preparing" } } = useTopic({
    topic: "onboardingWorkspace",
  });
  const ready = value.status === "ready" ? value.workspaceId : undefined;
  // The rest of the shell scopes to the active workspace; the Router name and
  // plugins the onboarding sets up belong to this one.
  const selectWorkspace = useSelectWorkspace();
  useEffect(() => {
    if (ready) selectWorkspace(ready);
  }, [ready, selectWorkspace]);
  return value;
}

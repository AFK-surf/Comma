import { renderHook } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { OnboardingWorkspace } from "../useOnboardingWorkspace";
import { useOnboardingRoutines } from "../useOnboardingRoutines";

const ready = { status: "ready", workspaceId: "wsp_1" } as const;
/** Reading the Routines creates them on this device's timezone. */
const read = ["wsp_1", { timezone: Intl.DateTimeFormat().resolvedOptions().timeZone }];

function routines({
  connected = true,
  workspace = ready,
}: { connected?: boolean; workspace?: OnboardingWorkspace } = {}) {
  const getRecommendations = vi.fn(async () => ({}) as never);
  const { result } = renderHook(() =>
    useOnboardingRoutines({
      api: { getRecommendations },
      connected,
      workspace,
    })
  );
  return { ...result.current, getRecommendations };
}

describe("useOnboardingRoutines", () => {
  it("starts the Routines once the apps step is answered with an app connected", () => {
    const { answered, getRecommendations, skipped } = routines();

    answered({ item: "name", name: "Atlas", named: true });
    expect(getRecommendations).not.toHaveBeenCalled();
    answered({
      item: "apps",
      connected: ["GitHub", "Notion"],
      ids: ["github", "notion"],
    });
    expect(getRecommendations).toHaveBeenCalledExactlyOnceWith(...read);
    // Once only, however the onboarding goes on.
    answered({ item: "apps", connected: ["GitHub"], ids: ["github"] });
    skipped();
    expect(getRecommendations).toHaveBeenCalledOnce();
  });

  it("starts them when Skip setup is pressed with an app connected", () => {
    const { getRecommendations, skipped } = routines();
    skipped();
    expect(getRecommendations).toHaveBeenCalledExactlyOnceWith(...read);
  });

  it("leaves the Routines to Home when no app was connected or the workspace is not ready", () => {
    const none = routines({ connected: false });
    none.answered({ item: "apps", connected: [], ids: [] });
    none.skipped();
    expect(none.getRecommendations).not.toHaveBeenCalled();

    const preparing = routines({ workspace: { status: "preparing" } });
    preparing.answered({ item: "apps", connected: ["GitHub"], ids: ["github"] });
    preparing.skipped();
    expect(preparing.getRecommendations).not.toHaveBeenCalled();
  });
});

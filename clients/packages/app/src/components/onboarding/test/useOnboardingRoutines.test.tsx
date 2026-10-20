import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { renderHook } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import type { OnboardingWorkspace } from "../useOnboardingWorkspace";
import { useOnboardingRoutines } from "../useOnboardingRoutines";

const ready = { status: "ready", workspaceId: "wsp_1" } as const;
/** Reading the Routines creates them on this device's timezone. */
const start = [
  "recommendations.start",
  { workspace: "wsp_1", timezone: Intl.DateTimeFormat().resolvedOptions().timeZone },
];

function routines({
  connected = true,
  workspace = ready,
}: { connected?: boolean; workspace?: OnboardingWorkspace } = {}) {
  const calls: unknown[][] = [];
  const core = createScriptedCore({
    calls: (name, params) => {
      calls.push([name, params]);
      return null;
    },
  });
  const { result } = renderHook(() => useOnboardingRoutines({ connected, workspace }), {
    wrapper: ({ children }) => core.wrap(children),
  });
  return { ...result.current, calls };
}

/** The core takes a call a few microtasks after it is made. */
async function settle() {
  for (let i = 0; i < 5; i += 1) await Promise.resolve();
}

describe("useOnboardingRoutines", async () => {
  it("starts the Routines once the apps step is answered with an app connected", async () => {
    const { answered, calls, skipped } = routines();

    answered({ item: "name", name: "Atlas", named: true });
    expect(calls).toEqual([]);
    answered({
      item: "apps",
      connected: ["GitHub", "Notion"],
      ids: ["github", "notion"],
    });
    // Once only, however the onboarding goes on.
    answered({ item: "apps", connected: ["GitHub"], ids: ["github"] });
    skipped();
    await settle();
    expect(calls).toEqual([start]);
  });

  it("starts them when Skip setup is pressed with an app connected", async () => {
    const { calls, skipped } = routines();
    skipped();
    await settle();
    expect(calls).toEqual([start]);
  });

  it("leaves the Routines to Home when no app was connected or the workspace is not ready", async () => {
    const none = routines({ connected: false });
    none.answered({ item: "apps", connected: [], ids: [] });
    none.skipped();
    await settle();
    expect(none.calls).toEqual([]);

    const preparing = routines({ workspace: { status: "preparing" } });
    preparing.answered({ item: "apps", connected: ["GitHub"], ids: ["github"] });
    preparing.skipped();
    await settle();
    expect(preparing.calls).toEqual([]);
  });
});

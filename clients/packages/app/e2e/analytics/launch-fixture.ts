import type { NativeInfo } from "@comma/native-bridge";
import { startCommaAnalytics } from "../../src/analytics/client";

export function startLaunch(desktopLaunch: NativeInfo["desktopLaunch"]) {
  const snapshot = {
    authority: { authorityInstanceId: "fixture-main", kind: "electron_main" as const },
    contractVersion: 1 as const,
    generation: 1,
    revision: 1,
    cleanup: { revocation: "idle" as const },
    phase: "signed_out" as const,
    reason: "no_session" as const,
    principal: null,
    session: null,
  };
  return startCommaAnalytics({
    runtime: "electron",
    desktopLaunch: Promise.resolve(desktopLaunch),
    lifecycle: { getSnapshotSync: () => snapshot, subscribe: () => () => {} },
  });
}

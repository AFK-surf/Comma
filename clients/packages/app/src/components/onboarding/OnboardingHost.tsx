import { getNativeBridge } from "@comma/native-bridge";
import { OverlayPortalProvider } from "@comma/ui";
import { useCallback, useEffect, useRef, useState } from "react";
import { useCommaAuth } from "../auth-context";
import {
  useCommaClientSettings,
  useCommaClientSettingsPending,
} from "../commaClientSettings";
import { OnboardingExperience } from "./OnboardingExperience";
import { announceOnboardingHandoff } from "./onboardingHandoff";
import { useHoldOnboardingOpen } from "./onboardingPresence";

/**
 * - `idle`: nothing shown since this account last finished the onboarding;
 * - `presenting`: Main was asked for the onboarding window;
 * - `window`: the onboarding runs in that window, or it did not open and the
 *   next launch asks again (a new product lease asks again at once: Main
 *   refuses a request made with the lease it replaced);
 * - `overlay`: it runs over the product in this window.
 */
type Presentation = "idle" | "presenting" | "window" | "overlay";

/**
 * Shows the first-launch onboarding to a signed-in account that has not
 * finished it on this device. Mounted beside the product shell, outside the
 * chat-consumer boundary, so a product-lease generation bump keeps its place
 * in the flow; the owner keys it by account.
 *
 * Electron presents it in a window of its own over the whole display, and the
 * product here stands down for as long as that window is open. Main records
 * its completion in the client settings, which brings it here; removing
 * the account from them (the Debug replay) presents it again. Where Main
 * presents no window (the web), the overlay covers the product here instead.
 *
 * "Start chatting" hands the user to Home's composer once the onboarding has
 * left: after the overlay's exit, or when Main reports the hand-off after the
 * onboarding window closed.
 *
 * The overlay portals into a host rendered after the shell. Electron merges
 * window drag regions in document order, so the overlay's drag strip and
 * no-drag controls must come after the shell's own regions to win.
 */
export function OnboardingHost({ userId }: { userId: string }) {
  const { productLease } = useCommaAuth();
  const { settings, update } = useCommaClientSettings();
  const settingsPending = useCommaClientSettingsPending();
  const completedUserIds = settings.onboardingCompletedUserIds;
  const completed = completedUserIds.includes(userId);
  const windowOpen = useOnboardingWindowOpen();
  const [presentation, setPresentation] = useState<Presentation>("idle");
  // The overlay finished but the settings owner has not recorded it yet. A
  // failed write then shows it again on the next launch, not in a loop now.
  const [finished, setFinished] = useState(false);
  const [portalHost, setPortalHost] = useState<HTMLDivElement | null>(null);
  const presentRequest = useRef<Promise<void>>(undefined);
  // The lease of a request Main refused.
  const [refusedLease, setRefusedLease] = useState<typeof productLease>();

  useHoldOnboardingOpen(windowOpen);

  if (finished && completed) setFinished(false);
  // The window's turn ends once it has closed and its completion has arrived.
  // One that closed without recording it waits for the next launch.
  if (presentation === "window" && completed && !windowOpen) setPresentation("idle");
  if (
    presentation === "window" &&
    refusedLease &&
    (refusedLease.sessionId !== productLease.sessionId ||
      refusedLease.generation !== productLease.generation)
  ) {
    setRefusedLease(undefined);
    setPresentation(completed ? "idle" : "presenting");
  }
  // Decide on a settled owner snapshot, so a returning user never sees a flash.
  if (presentation === "idle" && !completed && !finished && !settingsPending) {
    setPresentation("presenting");
  }

  useEffect(() => {
    if (presentation !== "presenting" || presentRequest.current) return;
    const lease = productLease;
    presentRequest.current = getNativeBridge()
      .onboarding.presentWindow({ session: lease })
      .then(
        ({ presented }) => setPresentation(presented ? "window" : "overlay"),
        (error: unknown) => {
          console.error("[onboarding] the onboarding window did not open", error);
          setRefusedLease(lease);
          setPresentation("window");
        }
      )
      .finally(() => {
        presentRequest.current = undefined;
      });
  }, [presentation, productLease]);

  const complete = useCallback(() => {
    setFinished(true);
    void update({ onboardingCompletedUserIds: [...completedUserIds, userId] });
  }, [completedUserIds, update, userId]);
  const exited = useCallback(() => {
    setPresentation("idle");
    announceOnboardingHandoff();
  }, []);
  const getPortalHost = useCallback(() => portalHost, [portalHost]);

  return (
    <>
      <div data-comma-onboarding-host="" ref={setPortalHost} />
      {presentation === "overlay" && portalHost ? (
        <OverlayPortalProvider getContainer={getPortalHost}>
          <OnboardingExperience
            onComplete={complete}
            onExited={exited}
            presentation="overlay"
          />
        </OverlayPortalProvider>
      ) : null}
    </>
  );
}

/**
 * Whether Main's onboarding window is open over this window. Main also reports
 * a "Start chatting" hand-off once that window has closed.
 */
function useOnboardingWindowOpen() {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const bridge = getNativeBridge().onboarding;
    const unsubscribeWindow = bridge.window.subscribe((state) => setOpen(state.open));
    const unsubscribeHandoff = bridge.onHandoff(() => announceOnboardingHandoff());
    return () => {
      unsubscribeWindow();
      unsubscribeHandoff();
    };
  }, []);

  return open;
}

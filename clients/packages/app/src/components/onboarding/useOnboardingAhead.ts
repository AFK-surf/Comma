import { useContext } from "react";
import { CommaAuthContext } from "../auth-context";
import {
  useCommaClientSettingsPending,
  useOptionalCommaClientSettings,
} from "../commaClientSettings";
import { useOnboardingOpen } from "./onboardingPresence";

/**
 * Whether the first-launch onboarding is still ahead of this account, or
 * covers the product now. It is ahead until the account's completion is
 * recorded, finished or closed by hand, and while that record is still
 * loading. So a reader that must wait for the onboarding holds back from its
 * first render, before the onboarding window has even opened (the product
 * mounts first). Outside a signed-in session, a guest's included, only an
 * open onboarding counts.
 */
export function useOnboardingAhead(): boolean {
  const open = useOnboardingOpen();
  const auth = useContext(CommaAuthContext);
  const settings = useOptionalCommaClientSettings();
  const settingsPending = useCommaClientSettingsPending();
  if (open) return true;
  if (!auth?.userId || auth.isGuest || !settings) return false;
  return settingsPending || !settings.onboardingCompletedUserIds.includes(auth.userId);
}

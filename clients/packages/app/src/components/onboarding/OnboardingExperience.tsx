import { useState } from "react";
import { useCommaAuth } from "../auth-context";
import { useCommaClientSettings } from "../commaClientSettings";
import { useRouterIdentity } from "../router-identity/RouterIdentityProvider";
import { onboardingConnectedAppIds } from "./items/OnboardingAppsPanel";
import { OnboardingOverlay, randomOnboardingVoice } from "./OnboardingOverlay";
import type { OnboardingPresentation } from "./onboardingSetup";
import { LivePermissionsPanel } from "./permissions/PermissionsPanel";
import { usePermissionsStepAvailable } from "./permissions/usePermissionsStep";
import { useOnboardingPlugins } from "./useOnboardingPlugins";
import { useOnboardingRoutines } from "./useOnboardingRoutines";
import { useOnboardingWorkspace } from "./useOnboardingWorkspace";

export type { OnboardingPresentation } from "./onboardingSetup";

export type OnboardingExperienceProps = {
  presentation: OnboardingPresentation;
  /**
   * The user pressed "Start chatting" on the welcome page, the one way the
   * onboarding ends: record completion now. The user is handed to Home's
   * composer once the onboarding has left.
   */
  onComplete: () => void;
  /** The exit reveal has finished: unmount the overlay / close the window. */
  onExited: () => void;
};

/**
 * The whole first-launch experience (a conversation with Comma: its greeting,
 * then one exchange each to connect apps, name the assistant, and allow the
 * macOS grants where they exist, the Side Chat and the Open Comma shortcut in
 * the macOS app, and a welcome page) with its own session hooks.
 * Render it inside the signed-in providers (auth, client settings,
 * PluginInstallProvider, RouterIdentityProvider).
 *
 * It waits for the account's workspace itself, because every call it makes is
 * workspace-scoped; the grants join the conversation only where macOS offers
 * them.
 */
export function OnboardingExperience({
  onComplete,
  onExited,
  presentation,
}: OnboardingExperienceProps) {
  const auth = useCommaAuth();
  const { name, setRouterName } = useRouterIdentity();
  const workspace = useOnboardingWorkspace(auth.api);
  const plugins = useOnboardingPlugins({ api: auth.api, workspace });
  const routines = useOnboardingRoutines({
    api: auth.api,
    connected: onboardingConnectedAppIds(plugins.list).length > 0,
    workspace,
  });
  const permissionsAvailable = usePermissionsStepAvailable();
  // The macOS app's window tells of the Side Chat and teaches the Open Comma
  // shortcut, each where its shortcut is set.
  const { settings } = useCommaClientSettings();
  const mac = presentation === "window" && permissionsAvailable;
  const openShortcut = (mac && settings.openCommaShortcut) || undefined;
  const sideChatShortcut = (mac && settings.sideChatShortcut) || undefined;
  // A tone picked for this onboarding, kept to its end.
  const [voice] = useState(randomOnboardingVoice);

  return (
    <OnboardingOverlay
      onComplete={onComplete}
      onConnectPlugin={plugins.connect}
      onExited={onExited}
      onItemAnswered={routines.answered}
      onSkipSetup={routines.skipped}
      onSaveRouterName={setRouterName}
      plugins={plugins.list}
      presentation={presentation}
      renderPermissions={
        permissionsAvailable ? (slot) => <LivePermissionsPanel {...slot} /> : undefined
      }
      routerName={name}
      openShortcut={openShortcut}
      sideChatShortcut={sideChatShortcut}
      voice={voice}
      workspace={workspace}
    />
  );
}

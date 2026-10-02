import { useCommaMessages } from "@comma/i18n/react";
import type { SettingsCategoryDefinition } from "@comma/ui";
import { useCommaAuth } from "../auth-context";
import {
  useCommaClientSettings,
  useCommaClientSettingsPending,
} from "../commaClientSettings";
import { useCommaSettingsOverlay } from "../settingsOverlay";

type SettingsSection = SettingsCategoryDefinition["sections"][number];

/**
 * General's row that shows the first-launch onboarding again: it closes
 * Settings and forgets that this account finished it, and the onboarding
 * host opens it over the shell.
 */
export function useOnboardingReplaySection(): SettingsSection {
  const m = useCommaMessages();
  const { userId } = useCommaAuth();
  const { settings, update } = useCommaClientSettings();
  const pending = useCommaClientSettingsPending();
  const { closeSettings } = useCommaSettingsOverlay();
  const completedUserIds = settings.onboardingCompletedUserIds;

  return {
    id: "general.onboarding",
    title: m.settings_onboarding(),
    items: [
      {
        id: "app.onboarding.replay",
        title: m.settings_onboarding_replay(),
        description: m.settings_onboarding_replay_description(),
        keywords: ["onboarding", "first launch", "introduction", "新手引导", "引导"],
        control: {
          type: "button",
          disabled: pending || !userId || !completedUserIds.includes(userId),
          label: m.settings_onboarding_replay_action(),
          onPress: () => {
            closeSettings();
            void update({
              onboardingCompletedUserIds: completedUserIds.filter(
                (id) => id !== userId
              ),
            });
          },
        },
      },
    ],
  };
}

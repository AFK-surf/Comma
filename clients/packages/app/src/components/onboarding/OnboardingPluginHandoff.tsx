import { getNativeBridge } from "@comma/native-bridge";
import { useEffect } from "react";
import { usePluginInstall } from "../plugins/PluginInstallProvider";

/**
 * The onboarding window closed while an app was still being authorized in
 * the browser: this window verifies it from then on, so finishing consent
 * there still installs the app, and a failure is worded as the onboarding
 * words it. Mount it once, under the product's PluginInstallProvider.
 */
export function OnboardingPluginHandoff() {
  const { resume } = usePluginInstall();

  useEffect(
    () =>
      getNativeBridge().onboarding.onHandoff(({ pluginAuthorization }) => {
        if (pluginAuthorization) resume(pluginAuthorization, "onboarding");
      }),
    [resume]
  );

  return null;
}

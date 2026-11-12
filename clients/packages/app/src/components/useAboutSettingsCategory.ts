import { useCommaMessages } from "@comma/i18n/react";
import type { SettingsCategoryDefinition } from "@comma/ui/components/settings";
import { useEffect, useState } from "react";
import {
  runApplicationMenuCommand,
  useEnabledApplicationMenuCommands,
} from "./application-menu/useApplicationMenu";
import { useNativeInfoContext } from "./nativeInfoContext";

const checkParam = "check";

// `/#/settings?category=about&check=updates` (the status item's Check for
// Updates) opens About and checks once.
function readCheckRequest() {
  if (typeof window === "undefined") return false;
  const hash = window.location.hash;
  const queryStart = hash.indexOf("?");
  if (queryStart < 0) return false;
  return new URLSearchParams(hash.slice(queryStart + 1)).get(checkParam) === "updates";
}

// The request is spent once acted on: going back or reloading does not check
// again, and the next link with it is a change of hash that does.
function forgetCheckRequest() {
  const hash = window.location.hash;
  const queryStart = hash.indexOf("?");
  const params = new URLSearchParams(hash.slice(queryStart + 1));
  params.delete(checkParam);
  const query = params.toString();
  window.history.replaceState(
    window.history.state,
    "",
    `${hash.slice(0, queryStart)}${query ? `?${query}` : ""}`
  );
}

/**
 * The desktop app's About: the version it runs and Check for Updates, the
 * application menu's command (the menu bar on macOS; Windows has none).
 */
export function useAboutSettingsCategory(): SettingsCategoryDefinition | null {
  const m = useCommaMessages();
  const { appVersion, platform } = useNativeInfoContext();
  // Enabled while the desktop app's update owner is mounted and not already checking.
  const canCheck = useEnabledApplicationMenuCommands().includes("check-updates");
  const [checkRequested, setCheckRequested] = useState(readCheckRequest);

  useEffect(() => {
    if (typeof window === "undefined") return undefined;
    const sync = () => setCheckRequested(readCheckRequest());
    sync();
    window.addEventListener("hashchange", sync);
    window.addEventListener("popstate", sync);
    return () => {
      window.removeEventListener("hashchange", sync);
      window.removeEventListener("popstate", sync);
    };
  }, []);

  useEffect(() => {
    if (!checkRequested || !canCheck) return;
    setCheckRequested(false);
    forgetCheckRequest();
    runApplicationMenuCommand("check-updates");
  }, [canCheck, checkRequested]);

  if (platform !== "electron") return null;
  return {
    id: "about",
    icon: "about",
    label: m.settings_about(),
    keywords: ["about", "version", "update", "关于", "版本", "更新"],
    sections: [
      {
        id: "about.app",
        title: m.settings_about(),
        items: [
          {
            id: "about.version",
            title: m.settings_about_version(),
            description: appVersion,
            keywords: ["version", "update", "check for updates", "版本", "检查更新"],
            control: {
              type: "button",
              disabled: !canCheck,
              label: m.settings_about_check_updates(),
              onPress: () => runApplicationMenuCommand("check-updates"),
            },
          },
        ],
      },
    ],
  };
}

import type {
  AppLaunchAtLoginStatus,
  CommaOperatingSystem,
} from "@comma/native-bridge";

export type LaunchAtLoginStatus = AppLaunchAtLoginStatus;

export interface LaunchAtLoginReadback {
  enabled: boolean;
  status?: LaunchAtLoginStatus;
}

export interface LoginItemSettingsReadback {
  executableWillLaunchAtLogin?: boolean;
  openAtLogin: boolean;
  status?: LaunchAtLoginStatus;
}

export function resolveLaunchAtLoginReadback(
  os: CommaOperatingSystem,
  settings: LoginItemSettingsReadback
): LaunchAtLoginReadback {
  // Modeled in tla/app-preferences/AppPreferences.tla: native read-back, not
  // the requested value, is the authoritative externally owned state.
  if (os === "macos") {
    if (settings.status) {
      return {
        enabled: settings.status === "enabled",
        status: settings.status,
      };
    }
    return { enabled: settings.openAtLogin };
  }

  if (os === "windows") {
    return {
      enabled: settings.openAtLogin && settings.executableWillLaunchAtLogin === true,
    };
  }

  return { enabled: false };
}

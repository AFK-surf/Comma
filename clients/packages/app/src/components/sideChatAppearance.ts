import { useEffect, useState } from "react";
import type { CommaClientSideChatAppearance } from "@comma/native-bridge";
import { useCommaClientSettings } from "./commaClientSettings";
import type { CommaUiThemeName } from "./commaUiTheme";

export type { CommaUiThemeName } from "./commaUiTheme";

export type SideChatAppearance = CommaClientSideChatAppearance;

export function sideChatThemeName(
  appearance: SideChatAppearance
): CommaUiThemeName | undefined {
  if (appearance === "light") {
    return "Light mode";
  }
  if (appearance === "dark") {
    return "Dark mode";
  }
  return undefined;
}

function systemSideChatThemeName(): CommaUiThemeName {
  return typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-color-scheme: dark)").matches
    ? "Dark mode"
    : "Light mode";
}

export function useSideChatThemeName(appearance: SideChatAppearance): CommaUiThemeName {
  const explicitTheme = sideChatThemeName(appearance);
  const [systemTheme, setSystemTheme] = useState(systemSideChatThemeName);

  useEffect(() => {
    if (typeof window.matchMedia !== "function") {
      return;
    }

    const query = window.matchMedia("(prefers-color-scheme: dark)");
    const updateTheme = (event: MediaQueryListEvent) => {
      setSystemTheme(event.matches ? "Dark mode" : "Light mode");
    };
    query.addEventListener("change", updateTheme);
    return () => query.removeEventListener("change", updateTheme);
  }, []);

  return explicitTheme ?? systemTheme;
}

export function useSideChatAppearance() {
  return useCommaClientSettings().settings.sideChatAppearance;
}

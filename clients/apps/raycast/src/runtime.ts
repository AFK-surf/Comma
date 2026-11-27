// What every command shares: the chosen environment, the extension's store, and the API with its session.
import {
  LocalStorage,
  PopToRootType,
  Toast,
  getPreferenceValues,
  open,
  showHUD,
  showToast,
} from "@raycast/api";
import { randomUUID } from "node:crypto";
import { CommaApi, type Fetch } from "./lib/api";
import { environmentOf, environments } from "./lib/config";
import { CommaAppMissing, homeLink } from "./lib/links";
import { CommaStore } from "./lib/store";

export function runtime() {
  const environment = environmentOf(
    getPreferenceValues<{ environment?: string }>().environment
  );
  const config = environments[environment];
  const store = new CommaStore(
    {
      get: (key) => LocalStorage.getItem<string>(key),
      set: (key, value) => LocalStorage.setItem(key, value),
      remove: (key) => LocalStorage.removeItem(key),
    },
    environment
  );
  const api = (token?: string) => new CommaApi(config.apiOrigin, fetch as Fetch, token);
  return {
    scheme: config.scheme,
    store,
    api,
    // The system refuses a link no application takes. Say what that means, not the system's own error.
    open: async (url: string) => {
      try {
        await open(url);
      } catch {
        throw new CommaAppMissing();
      }
    },
    requestId: () => randomUUID(),
    platform: process.platform === "win32" ? ("windows" as const) : ("macos" as const),
  };
}

/** Says the Comma app could not be opened, when that is why `error` happened. True when it said so. */
export async function reportedMissingApp(error: unknown): Promise<boolean> {
  if (!(error instanceof CommaAppMissing)) return false;
  await showToast({
    style: Toast.Style.Failure,
    title: "Could not open Comma",
    message:
      "Install the Comma app, or check Comma Environment in this extension's settings.",
    primaryAction: {
      title: "Get Comma",
      onAction: () => open("https://comma.surf"),
    },
  });
  return true;
}

/** Opens the Comma desktop app, saying so if it is not installed or another environment is chosen. */
export async function openComma(): Promise<void> {
  const { open: openLink, scheme } = runtime();
  try {
    await openLink(homeLink(scheme));
  } catch (error) {
    if (!(await reportedMissingApp(error))) throw error;
  }
}

let disconnecting = false;

/** Signs the extension out of Comma. The Comma app stays signed in. */
export async function disconnect(options?: {
  /** Menu bar commands cannot show toasts. */
  toast?: boolean;
  /** Runs once the local session is cleared, before the HUD closes the window. */
  onDisconnected?: () => void;
}): Promise<void> {
  if (disconnecting) return;
  disconnecting = true;
  try {
    const { api, store } = runtime();
    const session = await store.session();
    if (options?.toast !== false) {
      await showToast({
        style: Toast.Style.Animated,
        title: "Disconnecting from Comma",
      });
    }
    if (session) {
      // The server ends the session first. If it cannot be reached, the session still leaves this computer.
      await api(session.token)
        .logout()
        .catch(() => undefined);
    }
    await store.clearSession();
    await store.clearPending();
    options?.onDisconnected?.();
    await showHUD("Disconnected from Comma", {
      popToRootType: PopToRootType.Immediate,
    });
  } finally {
    disconnecting = false;
  }
}

import { getNativeBridge } from "@comma/native-bridge";
import { useNavigate } from "@tanstack/react-router";
import { useCallback, useEffect, useState } from "react";

export type MiniAppOpenTarget = {
  appId: string;
  workspaceId: string;
  /** A Task card's preview Version; the live Version where not given. */
  version?: number | undefined;
};

/** The hash route that runs an app as the whole of its own window (`AppWindowRoute`), outside Comma's shell. */
export function miniAppWindowRoute({
  appId,
  workspaceId,
  version,
}: MiniAppOpenTarget): string {
  const path = `/apps/${encodeURIComponent(workspaceId)}/${encodeURIComponent(appId)}/window`;
  return version === undefined ? path : `${path}?version=${version}`;
}

/** A gallery app's window: the right panel's default width, and a phone's height. */
const APP_WINDOW_WIDTH = 440;
const APP_WINDOW_HEIGHT = 760;

/**
 * An app's open modes: the right panel beside what is on screen (the Apps gallery's, from anywhere without a chat
 * panel of its own), or (Mac) a window of its own that shows only the app. A new window needs no window role or native
 * permission of its own: its route leaves the shell out.
 */
export function useMiniAppOpenActions() {
  const navigate = useNavigate();
  const bridge = getNativeBridge();
  const inPanel = useCallback(
    (target: MiniAppOpenTarget) =>
      void navigate({
        to: "/apps/$workspaceId/$appId/run",
        params: { workspaceId: target.workspaceId, appId: target.appId },
        search: target.version === undefined ? {} : { version: target.version },
      }),
    [navigate]
  );
  // `from` is the element the app leaves (its right panel): the window opens on its place, so the app stays where it
  // was. Resolves once the window shows, with whether it opened. An app already in a window of its own is not opened
  // twice: that window comes to the front.
  const window = useCallback(
    async (target: MiniAppOpenTarget, from?: Element | null): Promise<boolean> => {
      if (bridge.platform !== "electron") return false;
      const route = miniAppWindowRoute(target);
      const open = await bridge.surfaces.state().then(
        ({ windows }) => windows.find((shown) => shown.route === route),
        () => undefined
      );
      if (open)
        return bridge.windows.focus({ windowId: open.id }).then(
          () => true,
          () => false
        );
      const view = globalThis.window;
      const rect = from?.getBoundingClientRect();
      // Without a place to take over (the Apps gallery), a window the size of a right panel, over this window's centre.
      const place =
        rect && rect.width > 0 && rect.height > 0
          ? rect
          : {
              left: (view.innerWidth - APP_WINDOW_WIDTH) / 2,
              top: (view.innerHeight - APP_WINDOW_HEIGHT) / 2,
              width: APP_WINDOW_WIDTH,
              height: Math.min(APP_WINDOW_HEIGHT, view.innerHeight),
            };
      const bounds = {
        x: Math.round(view.screenX + place.left),
        y: Math.round(view.screenY + Math.max(0, place.top)),
        width: Math.round(place.width),
        height: Math.round(place.height),
      };
      return bridge.windows.create({ route, bounds }).then(
        () => true,
        () => false
      );
    },
    [bridge]
  );
  return { inPanel, window, canOpenWindow: bridge.platform === "electron" };
}

/**
 * The windows open now (Mac) by route, each with its id: an app runs in a window of its own when its
 * `miniAppWindowRoute` is here. Empty elsewhere.
 */
export function useMiniAppWindows(): ReadonlyMap<string, string> {
  const [windows, setWindows] = useState<ReadonlyMap<string, string>>(noWindows);
  useEffect(() => {
    const bridge = getNativeBridge();
    if (bridge.platform !== "electron") return undefined;
    return bridge.surfaces.state.subscribe((state) =>
      setWindows(new Map(state.windows.map((shown) => [shown.route, shown.id])))
    );
  }, []);
  return windows;
}

const noWindows: ReadonlyMap<string, string> = new Map();

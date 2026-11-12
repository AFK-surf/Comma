import type { BrowserWindowConstructorOptions, Session, WebContents } from "electron";
import { miniAppRuntimeUrl } from "@comma/chat-contract/mini-app-runtime";
import { realMainClock, type MainClock } from "./clock";

interface SecurityLogger {
  warn(message: string, context?: Record<string, unknown>): void;
}

type WebContentsSecurityTarget = Pick<WebContents, "on" | "setWindowOpenHandler">;
type PermissionSessionTarget = Pick<
  Session,
  "setPermissionCheckHandler" | "setPermissionRequestHandler"
>;

const packagedRendererOrigin = "assets://.";

/** A dynamic UI widget or Comma app frame: it never navigates or redirects. */
const isSandboxedFrameUrl = (url: string | undefined) =>
  Boolean(url?.startsWith("comma-ui:") || url?.startsWith("comma-app:"));

export function installWindowSecurity({
  allowedNavigationOrigins = [],
  allowedWindowOpenOrigins = [],
  logger,
  handleAppLink,
  childWindowOptions,
  webContents,
}: {
  allowedNavigationOrigins?: string[];
  allowedWindowOpenOrigins?: string[];
  logger?: SecurityLogger;
  handleAppLink?: (url: string) => boolean;
  /** A child window of the page's own it may open (a screen window: screen-windows.ts), with its options. */
  childWindowOptions?: (details: {
    url: string;
    frameName: string;
    features: string;
  }) => BrowserWindowConstructorOptions | undefined;
  webContents: WebContentsSecurityTarget;
}) {
  const navigationOrigins = normalizeOriginSet([
    packagedRendererOrigin,
    ...allowedNavigationOrigins,
  ]);
  const windowOpenOrigins = normalizeOriginSet(allowedWindowOpenOrigins);

  webContents.setWindowOpenHandler(({ url, frameName, features }) => {
    if (handleAppLink?.(url)) return { action: "deny" };
    const child = childWindowOptions?.({
      url,
      frameName: frameName ?? "",
      features: features ?? "",
    });
    if (child) return { action: "allow", overrideBrowserWindowOptions: child };
    if (isAllowedUrl(url, windowOpenOrigins)) {
      return { action: "allow" };
    }

    logger?.warn("Blocked renderer window-open request.", { url });
    return { action: "deny" };
  });

  webContents.on("will-navigate", (event, url) => {
    if (handleAppLink?.(url)) {
      event.preventDefault();
      return;
    }
    if (isAllowedUrl(url, navigationOrigins)) {
      return;
    }

    event.preventDefault();
    logger?.warn("Blocked renderer navigation request.", { url });
  });
  webContents.on("will-frame-navigate", (event) => {
    if (
      isSandboxedFrameUrl(event.frame?.url) ||
      isSandboxedFrameUrl(event.initiator?.url)
    ) {
      event.preventDefault();
    }
  });
  webContents.on("will-redirect", (event) => {
    if (isSandboxedFrameUrl(event.frame?.url) || isSandboxedFrameUrl(event.url))
      event.preventDefault();
  });
}

/**
 * The network guard of sandboxed frames: dynamic UI widgets (`comma-ui:`) and
 * Comma apps (`comma-app:`). A session has one `onBeforeRequest` listener, so
 * both live here.
 *
 * A Comma app frame loads only the runtime document and `blob:` / `data:`
 * URLs (design AFK-surf/Cue#4070 §7.1). Every other request of the frame or a
 * frame inside it fails: http, https, WebSocket and every other scheme.
 */
export function installDynamicUiNetworkSecurity(
  target: Session,
  { clock = realMainClock }: { clock?: MainClock } = {}
) {
  // Frame-less Worker scripts share a window budget; attribution is not required.
  const budgets = new Map<
    number,
    { start: number; count: number; active: Set<number> }
  >();
  const pending = new Map<number, number>();
  target.webRequest.onBeforeRequest((details, callback) => {
    if (details.url.startsWith("comma-app:")) {
      callback({ cancel: details.url !== miniAppRuntimeUrl });
      return;
    }
    let app = details.referrer?.startsWith("comma-app:") ?? false;
    for (let ancestor = details.frame; ancestor && !app; ancestor = ancestor.parent)
      app = ancestor.url.startsWith("comma-app:");
    if (app) {
      callback({
        cancel: !details.url.startsWith("blob:") && !details.url.startsWith("data:"),
      });
      return;
    }
    let frame = details.frame;
    let card =
      pending.has(details.id) || (details.referrer?.startsWith("comma-ui:") ?? false);
    while (frame) {
      if (frame.url.startsWith("comma-ui:")) card = true;
      frame = frame.parent;
    }
    if (details.url.startsWith("comma-ui:")) {
      callback({ cancel: details.url !== "comma-ui://runtime/" });
      return;
    }
    const framelessScript =
      !details.frame &&
      details.resourceType === "script" &&
      details.url.startsWith("https://");
    if (!card && !framelessScript) {
      callback({ cancel: false });
      return;
    }
    if (
      !details.url.startsWith("https://") ||
      !["image", "stylesheet", "font", "script"].includes(details.resourceType)
    ) {
      callback({ cancel: true });
      return;
    }
    const key = details.webContentsId ?? -1;
    const now = clock.now();
    let budget = budgets.get(key);
    if (!budget) {
      budget = { start: now, count: 0, active: new Set() };
      budgets.set(key, budget);
      details.webContents?.once("destroyed", () => budgets.delete(key));
    }
    if (now - budget.start >= 10_000) {
      budget.start = now;
      budget.count = 0;
    }
    // Redirects re-enter this handler and spend another request from the budget.
    if (
      ++budget.count > 128 ||
      (budget.active.size >= 8 && !budget.active.has(details.id))
    ) {
      callback({ cancel: true });
      return;
    }
    budget.active.add(details.id);
    pending.set(details.id, key);
    callback({ cancel: false });
  });
  target.webRequest.onBeforeSendHeaders((details, callback) => {
    const requestHeaders = { ...details.requestHeaders };
    if (pending.has(details.id)) {
      for (const name of Object.keys(requestHeaders)) {
        if (
          ["cookie", "authorization", "proxy-authorization", "referer"].includes(
            name.toLowerCase()
          )
        )
          delete requestHeaders[name];
      }
    }
    callback({ requestHeaders });
  });
  const finish = (details: { id: number }) => {
    const key = pending.get(details.id);
    if (key !== undefined) budgets.get(key)?.active.delete(details.id);
    pending.delete(details.id);
  };
  target.webRequest.onCompleted(finish);
  target.webRequest.onErrorOccurred(finish);
}

/**
 * What the app's own page may use: its voice call and the device capabilities that Comma apps use through it.
 * `keyboardLock`: a remote screen that fills the screen while the person controls it takes Escape for the computer
 * (`navigator.keyboard.lock`); holding Escape still leaves full screen. Electron refuses the lock without it.
 */
const appPagePermissions = new Set([
  "media",
  "midi",
  "midiSysex",
  "fullscreen",
  "keyboardLock",
  "screen-wake-lock",
  "geolocation",
]);

/** What a screen window may ask (screen-windows.ts): its screen fills the screen, and takes Escape while controlled. */
const screenWindowPermissions = new Set(["fullscreen", "keyboardLock"]);

/**
 * Every permission is refused, except for the app's own page (`appOrigins`, its top frame): the microphone and camera
 * (requested, and checked so the page sees the devices' names),
 * MIDI, full screen, the keyboard lock and the screen wake lock. Electron reports all MIDI requests as midiSysex.
 * The SDK requests MIDI without system exclusive messages. Mini-app frames may request USB
 * devices through the device chooser when their iframe policy permits it. Their origin stays opaque.
 * Screen capture and other origins stay refused.
 */
export function installSessionSecurity(
  session: PermissionSessionTarget,
  {
    appOrigins = [],
    appChildWindow = () => false,
  }: {
    appOrigins?: readonly string[];
    /** A screen window of the app's page (screen-windows.ts): its blank top document is the page's own. */
    appChildWindow?: (webContents: WebContents | null) => boolean;
  } = {}
) {
  const app = normalizeOriginSet([...appOrigins]);
  const appTop = (url: string | undefined, isMainFrame: boolean | undefined) => {
    const origin = url ? normalizeOrigin(url) : undefined;
    return isMainFrame === true && origin !== undefined && app.has(origin);
  };
  // The page's own media check: without it the browser hides the names and IDs of audio inputs, and a Comma app
  // cannot choose one.
  session.setPermissionCheckHandler(
    (webContents, permission, requestingOrigin, details) => {
      const check = (details ?? {}) as {
        mediaType?: string;
        isMainFrame?: boolean;
        requestingUrl?: string;
      };
      if (permission === "usb")
        return (
          check.isMainFrame === false &&
          check.requestingUrl === miniAppRuntimeUrl &&
          Boolean(webContents && isAllowedUrl(webContents.getURL(), app))
        );
      return (
        permission === "media" &&
        (check.mediaType === "audio" || check.mediaType === "video") &&
        appTop(check.requestingUrl ?? requestingOrigin, check.isMainFrame)
      );
    }
  );
  session.setPermissionRequestHandler((webContents, permission, callback, details) => {
    const request = (details ?? {}) as {
      mediaTypes?: string[];
      isMainFrame?: boolean;
      requestingUrl?: string;
    };
    const media =
      permission !== "media" ||
      (Array.isArray(request.mediaTypes) &&
        request.mediaTypes.length > 0 &&
        request.mediaTypes.every((type) => type === "audio" || type === "video"));
    // A screen window's blank document is the app's page's own: it may fill the screen and take Escape, nothing else.
    if (
      request.isMainFrame === true &&
      request.requestingUrl === "about:blank" &&
      appChildWindow(webContents)
    ) {
      callback(screenWindowPermissions.has(permission));
      return;
    }
    callback(
      appPagePermissions.has(permission) &&
        media &&
        appTop(request.requestingUrl, request.isMainFrame)
    );
  });
}

export function allowedRendererOrigins(devServerUrl?: string) {
  return [packagedRendererOrigin, devServerUrl]
    .filter((origin): origin is string => Boolean(origin))
    .map(normalizeOrigin)
    .filter((origin): origin is string => Boolean(origin));
}

export function isAllowedUrl(url: string, allowedOrigins: ReadonlySet<string>) {
  const origin = normalizeOrigin(url);

  return Boolean(origin && allowedOrigins.has(origin));
}

function normalizeOriginSet(origins: string[]) {
  return new Set(
    origins.map(normalizeOrigin).filter((origin): origin is string => Boolean(origin))
  );
}

function normalizeOrigin(value: string) {
  try {
    const url = new URL(value);

    if (url.protocol === "assets:" && url.hostname === ".") {
      return packagedRendererOrigin;
    }

    return url.origin;
  } catch {
    return undefined;
  }
}

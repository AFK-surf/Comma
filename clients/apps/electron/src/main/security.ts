import type { Session, WebContents } from "electron";
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
const miniAppRuntimeUrl = "comma-app://runtime/";

/** A dynamic UI widget or Comma app frame: it never navigates or redirects. */
const isSandboxedFrameUrl = (url: string | undefined) =>
  Boolean(url?.startsWith("comma-ui:") || url?.startsWith("comma-app:"));

export function installWindowSecurity({
  allowedNavigationOrigins = [],
  allowedWindowOpenOrigins = [],
  logger,
  handleAppLink,
  webContents,
}: {
  allowedNavigationOrigins?: string[];
  allowedWindowOpenOrigins?: string[];
  logger?: SecurityLogger;
  handleAppLink?: (url: string) => boolean;
  webContents: WebContentsSecurityTarget;
}) {
  const navigationOrigins = normalizeOriginSet([
    packagedRendererOrigin,
    ...allowedNavigationOrigins,
  ]);
  const windowOpenOrigins = normalizeOriginSet(allowedWindowOpenOrigins);

  webContents.setWindowOpenHandler(({ url }) => {
    if (handleAppLink?.(url)) return { action: "deny" };
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
 * Every permission is refused, except the microphone alone for the app's own page (`microphoneOrigins`, its top
 * frame) while `microphoneAllowed` says so (voice labs on): the desktop's voice call records it there. Cameras,
 * screens and other origins stay refused.
 */
export function installSessionSecurity(
  session: PermissionSessionTarget,
  {
    microphoneOrigins = [],
    microphoneAllowed = async () => false,
  }: {
    microphoneOrigins?: readonly string[];
    microphoneAllowed?: () => Promise<boolean>;
  } = {}
) {
  const microphone = normalizeOriginSet([...microphoneOrigins]);
  session.setPermissionCheckHandler(() => false);
  session.setPermissionRequestHandler((_webContents, permission, callback, details) => {
    const media = (details ?? {}) as {
      mediaTypes?: string[];
      isMainFrame?: boolean;
      requestingUrl?: string;
    };
    const origin = media.requestingUrl
      ? normalizeOrigin(media.requestingUrl)
      : undefined;
    const appMicrophone =
      permission === "media" &&
      media.isMainFrame === true &&
      Array.isArray(media.mediaTypes) &&
      media.mediaTypes.length > 0 &&
      media.mediaTypes.every((type) => type === "audio") &&
      origin !== undefined &&
      microphone.has(origin);
    if (!appMicrophone) {
      callback(false);
      return;
    }
    microphoneAllowed().then(
      (allowed) => callback(allowed),
      () => callback(false)
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

import type { Session, WebContents } from "electron";

interface SecurityLogger {
  warn(message: string, context?: Record<string, unknown>): void;
}

type WebContentsSecurityTarget = Pick<WebContents, "on" | "setWindowOpenHandler">;
type PermissionSessionTarget = Pick<
  Session,
  "setPermissionCheckHandler" | "setPermissionRequestHandler"
>;

const packagedRendererOrigin = "assets://.";

export function installWindowSecurity({
  allowedNavigationOrigins = [],
  allowedWindowOpenOrigins = [],
  logger,
  webContents,
}: {
  allowedNavigationOrigins?: string[];
  allowedWindowOpenOrigins?: string[];
  logger?: SecurityLogger;
  webContents: WebContentsSecurityTarget;
}) {
  const navigationOrigins = normalizeOriginSet([
    packagedRendererOrigin,
    ...allowedNavigationOrigins,
  ]);
  const windowOpenOrigins = normalizeOriginSet(allowedWindowOpenOrigins);

  webContents.setWindowOpenHandler(({ url }) => {
    if (isAllowedUrl(url, windowOpenOrigins)) {
      return { action: "allow" };
    }

    logger?.warn("Blocked renderer window-open request.", { url });
    return { action: "deny" };
  });

  webContents.on("will-navigate", (event, url) => {
    if (isAllowedUrl(url, navigationOrigins)) {
      return;
    }

    event.preventDefault();
    logger?.warn("Blocked renderer navigation request.", { url });
  });
  webContents.on("will-frame-navigate", (event) => {
    if (
      event.frame?.url.startsWith("comma-ui:") ||
      event.initiator?.url.startsWith("comma-ui:")
    ) {
      event.preventDefault();
    }
  });
  webContents.on("will-redirect", (event) => {
    if (event.frame?.url.startsWith("comma-ui:") || event.url.startsWith("comma-ui:"))
      event.preventDefault();
  });
}

export function installDynamicUiNetworkSecurity(target: Session) {
  // Frame-less Worker scripts share a window budget; attribution is not required.
  const budgets = new Map<
    number,
    { start: number; count: number; active: Set<number> }
  >();
  const pending = new Map<number, number>();
  target.webRequest.onBeforeRequest((details, callback) => {
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
    const now = Date.now();
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

export function installSessionSecurity(session: PermissionSessionTarget) {
  session.setPermissionCheckHandler(() => false);
  session.setPermissionRequestHandler((_webContents, _permission, callback) => {
    callback(false);
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

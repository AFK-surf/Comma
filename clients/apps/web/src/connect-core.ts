import { CoreClient, workerCoreOpener } from "@comma/core-client";

/**
 * The client core for this page: this tab's worker runs it, or relays to the tab whose worker does. The core runs the
 * session (the Cookie's sign-in, sign-out and checks).
 */
export function connectWebCore(
  apiBaseUrl: string,
  options?: ConstructorParameters<typeof CoreClient>[1]
) {
  const core = new CoreClient(
    workerCoreOpener(
      () =>
        new Worker(new URL("./core.worker.ts", import.meta.url), {
          name: `comma-core:${apiBaseUrl}`,
          type: "module",
        })
    ),
    options
  );
  const unwire = wirePageToCore(core, apiBaseUrl);
  const dispose = () => {
    unwire();
    core.close();
  };
  return { core, dispose };
}

/**
 * What the page tells the core: it goes into the back/forward cache and comes back (the core forgot it meanwhile),
 * and it comes back to the person (focus, online), when the core checks the session with the server. A guest import
 * the page's old session adapter noted goes to the core once.
 */
export function wirePageToCore(core: CoreClient, apiBaseUrl: string): () => void {
  const reconcile = () =>
    void core.call("session.reconcile", { reason: "focus" }).catch(() => undefined);
  const onPageHide = () => core.suspend();
  const onPageShow = (event: PageTransitionEvent) => {
    if (!event.persisted) return;
    core.resume();
    reconcile();
  };
  window.addEventListener("pagehide", onPageHide);
  window.addEventListener("pageshow", onPageShow);
  window.addEventListener("focus", reconcile);
  window.addEventListener("online", reconcile);
  handOverGuestImport(core, apiBaseUrl);
  return () => {
    window.removeEventListener("pagehide", onPageHide);
    window.removeEventListener("pageshow", onPageShow);
    window.removeEventListener("focus", reconcile);
    window.removeEventListener("online", reconcile);
  };
}

/**
 * A guest's chat waiting to be imported, as the page's session adapter (before the core ran the session) noted it in
 * localStorage, which the core's worker cannot read: handed to the core once, then removed.
 */
function handOverGuestImport(core: CoreClient, apiBaseUrl: string) {
  let key: string;
  let raw: string | null;
  try {
    key = `comma.guestImportPending.v1:${new URL(apiBaseUrl, location.href).origin}`;
    raw = localStorage.getItem(key);
  } catch {
    return;
  }
  if (raw === null) return;
  const forget = () => {
    try {
      localStorage.removeItem(key);
    } catch {
      // Storage went away: nothing is left to hand over twice.
    }
  };
  let expiresAtEpochSeconds: unknown;
  try {
    expiresAtEpochSeconds = (JSON.parse(raw) as { expiresAtEpochSeconds?: unknown })
      ?.expiresAtEpochSeconds;
  } catch {
    expiresAtEpochSeconds = undefined;
  }
  if (
    typeof expiresAtEpochSeconds !== "number" ||
    !Number.isSafeInteger(expiresAtEpochSeconds) ||
    expiresAtEpochSeconds <= 0
  ) {
    forget();
    return;
  }
  // Kept until the core has it: a page closed first hands it over next time.
  core
    .call("session.guest.handOverImport", { expiresAtEpochSeconds })
    .then(forget, () => undefined);
}

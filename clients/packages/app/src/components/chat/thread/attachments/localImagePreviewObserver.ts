import {
  COMMA_SURFACE_PAUSED_ATTRIBUTE,
  COMMA_SURFACE_PAUSED_SELECTOR,
  isCommaSurfacePaused,
} from "../../../commaSurfacePause";

type LocalImagePreviewObserverGroup = {
  activation: IntersectionObserver;
  retention: IntersectionObserver;
  targets: Map<Element, (nearViewport: boolean) => void>;
};

const localImagePreviewObserverGroups = new Map<
  Element | null,
  LocalImagePreviewObserverGroup
>();

export function observeLocalImagePreview(
  element: Element,
  onNearViewport: (nearViewport: boolean) => void
) {
  if (typeof IntersectionObserver !== "function") {
    onNearViewport(true);
    return () => {};
  }

  // A document-root observer is still clipped by this nested overflow
  // viewport before rootMargin is applied. Root each shared observer pair at
  // the owning chat scrollport so the activation and retention bands have
  // their intended distance in production Chromium.
  const root = element.closest('[data-slot="scroll-area-viewport"]');
  const syncNearViewport = () => {
    if (isCommaSurfacePaused(element)) return;
    if (shouldDeferLocalImagePreviewSync(element, root)) return;
    onNearViewport(isWithinLocalImagePreviewActivationBand(element, root));
  };
  // IntersectionObserver delivers its initial result asynchronously. Classify
  // the already-laid-out node before passive effects run so a visible message
  // mounted by send can acquire the Composer's lease in the same task, before
  // the cache's last-release retirement microtask revokes the shared URL.
  // Reload/first-pin is the opposite: the thread is still at scrollTop 0 while
  // stick-to-bottom is about to jump to the latest turn. Syncing that frame
  // treats the oldest image groups as visible and floods Main before Chat or
  // Tasks can paint. Stick-to-bottom runs in a parent layout effect, so wait
  // one animation frame before classifying a top-pinned overflowing thread.
  let pinFrame = 0;
  if (!shouldDeferLocalImagePreviewSync(element, root)) {
    syncNearViewport();
  } else if (typeof requestAnimationFrame === "function") {
    pinFrame = requestAnimationFrame(() => {
      pinFrame = 0;
      syncNearViewport();
    });
  }
  let group = localImagePreviewObserverGroups.get(root);
  if (!group) {
    const targets = new Map<Element, (nearViewport: boolean) => void>();
    const activation = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (isCommaSurfacePaused(entry.target)) continue;
          if (shouldDeferLocalImagePreviewSync(entry.target, root)) continue;
          if (!entry.isIntersecting && entry.intersectionRatio <= 0) continue;
          targets.get(entry.target)?.(true);
        }
      },
      { root, rootMargin: "240px 0px" }
    );
    const retention = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting || entry.intersectionRatio > 0) continue;
          // Overlay hide/reveal queues a stale "left the band" callback.
          // Re-check the live box: visibility:hidden keeps layout, so a
          // Settings round-trip must not drop preview leases and refetch
          // every workspace image from Main.
          if (shouldRetainLocalImagePreview(entry.target, root)) continue;
          targets.get(entry.target)?.(false);
        }
      },
      { root, rootMargin: "720px 0px" }
    );
    group = { activation, retention, targets };
    localImagePreviewObserverGroups.set(root, group);
  }
  group.targets.set(element, onNearViewport);
  group.activation.observe(element);
  group.retention.observe(element);
  const observerGroup = group;

  const pauseHost = element.closest(COMMA_SURFACE_PAUSED_SELECTOR);
  const pauseObserver =
    pauseHost && typeof MutationObserver === "function"
      ? new MutationObserver(() => {
          if (isCommaSurfacePaused(element)) return;
          syncNearViewport();
          observerGroup.activation.unobserve(element);
          observerGroup.retention.unobserve(element);
          observerGroup.activation.observe(element);
          observerGroup.retention.observe(element);
        })
      : undefined;
  if (pauseHost && pauseObserver) {
    pauseObserver.observe(pauseHost, {
      attributes: true,
      attributeFilter: [COMMA_SURFACE_PAUSED_ATTRIBUTE],
    });
  }

  return () => {
    if (pinFrame !== 0) cancelAnimationFrame(pinFrame);
    pauseObserver?.disconnect();
    if (!group?.targets.delete(element)) return;
    group.activation.unobserve(element);
    group.retention.unobserve(element);
    if (group.targets.size === 0) {
      group.activation.disconnect();
      group.retention.disconnect();
      localImagePreviewObserverGroups.delete(root);
    }
  };
}

function shouldRetainLocalImagePreview(element: Element, root: Element | null) {
  return (
    isCommaSurfacePaused(element) ||
    isWithinLocalImagePreviewActivationBand(element, root)
  );
}

function isWithinLocalImagePreviewActivationBand(
  element: Element,
  root: Element | null
) {
  const targetRect = element.getBoundingClientRect();
  const rootRect = root?.getBoundingClientRect();
  const rootTop = rootRect?.top ?? 0;
  const rootBottom =
    rootRect?.bottom ??
    Math.max(document.documentElement.clientHeight, window.innerHeight);

  // A zero-sized scrollport means layout is not measurable yet. Keep the
  // target dormant until the observer's authoritative initial callback.
  if (rootBottom <= rootTop) return false;
  return targetRect.bottom >= rootTop - 240 && targetRect.top <= rootBottom + 240;
}

function shouldDeferLocalImagePreviewSync(element: Element, root: Element | null) {
  // Reports do not pin to the latest turn. Their first screen can load immediately.
  if (!(root instanceof HTMLElement) || !element.closest(".comma-chat-thread"))
    return false;
  if (root.scrollTop > 1 || root.scrollHeight <= root.clientHeight + 1) {
    return false;
  }

  // The current turn is intentionally allowed to start at scrollTop 0: when
  // it fits the reading model, stick-to-bottom anchors that turn at the top and
  // lets its content grow downward. Treating every overflowing scrollTop 0 as
  // the transient pre-pin state leaves current-turn images dormant forever.
  // Only older turns need the one-frame guard against loading the old top of a
  // transcript before initial pinning has settled.
  return element.closest('[data-chat-latest-turn="true"]') === null;
}

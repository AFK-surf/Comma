/**
 * The briefing carries two kinds of link. Prose renders ordinary anchors, and
 * a structured inline chip renders a button — it opens through the rail's own
 * handler rather than navigating, so its destination has nowhere to live but a
 * data attribute. A right-click has to find both.
 */
export const recommendationLinkHrefAttribute = "data-recommendation-href";

const RECOMMENDATION_LINK_SELECTOR = `a[href], [${recommendationLinkHrefAttribute}]`;

function eventTargetElement(target: EventTarget | null): Element | null {
  if (target instanceof Element) return target;
  if (target instanceof Node) return target.parentElement;
  return null;
}

/**
 * The external URL a pointer event landed on inside `root`, or null when it
 * landed on anything else.
 *
 * Same-origin destinations are not links out of the app — they are the app's
 * own routes — so they resolve to null and leave the platform's own menu
 * alone, exactly as chat does.
 */
export function resolveRecommendationLinkFromEventTarget(
  target: EventTarget | null,
  root: Element
): string | null {
  const element = eventTargetElement(target);
  const link = element?.closest<HTMLElement>(RECOMMENDATION_LINK_SELECTOR);
  if (!link || !root.contains(link)) return null;

  const href =
    link.getAttribute(recommendationLinkHrefAttribute) ?? link.getAttribute("href");
  if (!href) return null;

  let url: URL;
  try {
    url = new URL(href);
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  if (typeof window !== "undefined" && url.origin === window.location.origin)
    return null;
  return url.toString();
}

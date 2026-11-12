/**
 * Re-materializes a token glyph from stored markup. The markup originates in
 * our own menu render, but restored rich values cross the component boundary,
 * so only inert `<svg>`/`<img>` content is accepted: scripts, foreignObject,
 * event handlers, links, and non-image URLs are dropped.
 */
export function sanitizedTokenIconElement(markup: string): Element | null {
  const root = new DOMParser().parseFromString(markup, "text/html").body
    .firstElementChild;
  if (!root) return null;

  const tag = root.tagName.toLowerCase();
  if (tag === "img") {
    const src = root.getAttribute("src") ?? "";
    if (!/^(?:https?:|data:image\/|blob:)/u.test(src)) return null;
    // A bundled logo (a model vendor's) becomes a mask over the token's text
    // color, so it reads as one glyph like the SVG ones. A cross-origin image
    // cannot be a mask without CORS and keeps its own colors.
    if (!/^https?:/u.test(src) || new URL(src).origin === location.origin) {
      const glyph = document.createElement("span");
      glyph.dataset.tokenIconMask = "";
      glyph.style.setProperty("--comma-token-icon-mask", `url(${JSON.stringify(src)})`);
      return glyph;
    }
    const image = document.createElement("img");
    image.src = src;
    image.alt = "";
    image.draggable = false;
    return image;
  }
  if (tag !== "svg") return null;

  root.querySelectorAll("script, foreignObject").forEach((child) => child.remove());
  stripUnsafeTokenIconAttributes(root);
  root.querySelectorAll("*").forEach(stripUnsafeTokenIconAttributes);
  return document.importNode(root, true);
}

function stripUnsafeTokenIconAttributes(element: Element) {
  // Snapshot first: removing while iterating a live NamedNodeMap skips items.
  for (const attribute of Array.from(element.attributes)) {
    // class/style go too: the glyph must drop its menu colors (e.g. a task
    // status tint) and take the token's text color; the slot sets its size.
    if (
      /^on/iu.test(attribute.name) ||
      /href$/iu.test(attribute.name) ||
      attribute.name === "class" ||
      attribute.name === "style"
    ) {
      element.removeAttribute(attribute.name);
    }
  }
}

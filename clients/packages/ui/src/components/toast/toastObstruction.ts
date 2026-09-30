/**
 * A native surface — an Electron `WebContentsView`, such as the browser in the
 * right sidebar — composites above the renderer's entire DOM. No z-index lifts
 * a toast over one, so the stack steps aside instead: a surface covering the
 * window's right edge reports how far in from that edge it reaches, and
 * `Toaster` anchors its cards to the left of the widest live claim.
 *
 * Claims are keyed so surfaces that come and go independently (one per browser
 * tab) can each hold one, and the property is written only when the resolved
 * width changes — a sidebar resize drag republishes on every frame.
 *
 * The width reaches its readers as an inline custom property on each
 * registered target (`registerToastObstructionTarget`), never on the document
 * root: an inherited custom property written on `<html>` invalidates the style
 * of every element in the window, so a per-frame republish would cost a
 * whole-document style recalc per frame (measured ~30ms in the dev client).
 * Written on the toast host and the transfer panel, it invalidates only them.
 */
export const toastObstructionRightProperty = "--comma-toast-obstruction-right";

const claims = new Map<string, number>();
const targets = new Set<HTMLElement>();
let publishedWidth = 0;

const write = (target: HTMLElement) => {
  target.style.setProperty(toastObstructionRightProperty, `${publishedWidth}px`);
};

const publish = () => {
  let widest = 0;
  for (const width of claims.values()) {
    if (width > widest) widest = width;
  }
  if (widest === publishedWidth) return;
  publishedWidth = widest;
  for (const target of targets) write(target);
};

/**
 * Makes `target` read the live obstruction through
 * `var(--comma-toast-obstruction-right, 0px)`. Returns the unregister function.
 */
export const registerToastObstructionTarget = (target: HTMLElement) => {
  targets.add(target);
  write(target);
  return () => {
    targets.delete(target);
    target.style.removeProperty(toastObstructionRightProperty);
  };
};

/**
 * Reports that `claimId` covers `width` px of the window measured from its
 * right edge. Sub-pixel widths round up so the stack never lands a hair under
 * the surface it is avoiding.
 */
export const claimToastObstructionRight = (claimId: string, width: number) => {
  const claimed = Math.max(0, Math.ceil(width));
  if (claims.get(claimId) === claimed) return;
  claims.set(claimId, claimed);
  publish();
};

/**
 * Drops `claimId`'s claim. The stack returns to the window's own corner once no
 * claim remains.
 */
export const releaseToastObstructionRight = (claimId: string) => {
  if (!claims.delete(claimId)) return;
  publish();
};

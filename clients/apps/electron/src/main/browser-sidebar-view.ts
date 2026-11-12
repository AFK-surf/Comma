import type { BrowserSidebarCornerRadii } from "@comma/native-bridge";
import { View, type WebContentsView } from "electron";
import type { BrowserSidebarViewLike } from "./modules/browser-sidebar";

/**
 * Holds a sidebar page in a clip View, so that the page rounds only the
 * corners it shares with the rounded panel around it: the panel's CSS clip
 * cannot reach a native view. Electron rounds a View on all four corners with
 * one radius, so the clip reaches past the page by that radius on each side
 * whose two corners stay square, and its rounded corners there fall outside
 * the page. A View takes the presses over all of its bounds, so the clip sits
 * in a square frame exactly the page's size: the frame cuts what of the clip
 * reaches past the page, and the renderer beside the page (the sidebar's
 * resize edge, the browser toolbar) keeps its pointer. New radii take effect
 * with the next bounds.
 */
export function clipBrowserSidebarView(page: WebContentsView): BrowserSidebarViewLike {
  const frame = new View();
  const clip = new View();
  // A View clips its children only with a compositing layer of its own
  // (Electron 42 to 45). A zero-duration bounds animation creates that layer
  // once, without visible movement.
  for (const view of [frame, clip]) {
    view.setBounds({ height: 0, width: 0, x: 0, y: 0 }, { animate: { duration: 0 } });
  }
  frame.addChildView(clip);
  clip.addChildView(page);
  let radius = 0;
  let margins = { bottom: 0, left: 0, right: 0, top: 0 };

  return {
    nativeView: frame,
    webContents: page.webContents,
    getBounds: () => frame.getBounds(),
    getVisible: () => frame.getVisible(),
    setBackgroundColor: (color) => page.setBackgroundColor(color),
    setBounds: (bounds) => {
      const { height, width } = bounds;
      frame.setBounds(bounds);
      clip.setBounds({
        height: height + margins.top + margins.bottom,
        width: width + margins.left + margins.right,
        x: 0 - margins.left,
        y: 0 - margins.top,
      });
      page.setBounds({ height, width, x: margins.left, y: margins.top });
    },
    setCornerRadii: (radii: BrowserSidebarCornerRadii) => {
      const next = Math.max(
        radii.topLeft,
        radii.topRight,
        radii.bottomRight,
        radii.bottomLeft
      );
      const reach = (first: number, second: number) =>
        first === 0 && second === 0 ? next : 0;
      margins = {
        bottom: reach(radii.bottomLeft, radii.bottomRight),
        left: reach(radii.topLeft, radii.bottomLeft),
        right: reach(radii.topRight, radii.bottomRight),
        top: reach(radii.topLeft, radii.topRight),
      };
      if (next !== radius) {
        radius = next;
        clip.setBorderRadius(radius);
      }
    },
    setVisible: (visible) => frame.setVisible(visible),
  };
}

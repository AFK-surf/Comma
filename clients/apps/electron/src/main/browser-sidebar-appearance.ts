import { View, type WebContentsView } from "electron";
import type { BrowserSidebarViewLike } from "./modules/browser-sidebar";

/** Clip the floating browser's bottom corners without rounding its content top. */
export function applyBrowserSidebarAppearance(
  view: WebContentsView,
  radius: number
): BrowserSidebarViewLike {
  if (!radius) return view;
  const clip = new View();
  // In Electron 42 a View clip without its own compositing layer does not clip
  // native WebContentsView children. A zero-duration bounds animation creates
  // that layer once, without visible movement; resize uses plain setBounds.
  clip.setBounds({ x: 0, y: 0, width: 0, height: 0 }, { animate: { duration: 0 } });
  clip.setBorderRadius(radius);
  clip.addChildView(view);
  return {
    nativeView: clip,
    webContents: view.webContents,
    getBounds: () => {
      const bounds = clip.getBounds();
      return { ...bounds, y: bounds.y + radius, height: bounds.height - radius };
    },
    setBounds: (bounds) => {
      // The rounded top of the transparent clip lies above the webpage. Its
      // bottom matches the panel; webpage layout and input coordinates stay intact.
      clip.setBounds({
        ...bounds,
        y: bounds.y - radius,
        height: bounds.height + radius,
      });
      view.setBounds({ x: 0, y: radius, width: bounds.width, height: bounds.height });
    },
    getVisible: () => clip.getVisible(),
    setVisible: (visible) => clip.setVisible(visible),
    setBackgroundColor: (color) => view.setBackgroundColor(color),
  };
}

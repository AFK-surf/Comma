import type { SurfaceBounds } from "@comma/native-bridge";
import { describe, expect, it, vi } from "vitest";

const electron = vi.hoisted(() => {
  // Electron's View as the frame and the clip use it: bounds relative to the
  // parent, one border radius for all four corners, and children.
  class View {
    bounds = { height: 0, width: 0, x: 0, y: 0 };
    borderRadius = 0;
    readonly children: View[] = [];
    visible = true;
    addChildView(child: View) {
      this.children.push(child);
    }
    getBounds() {
      return this.bounds;
    }
    getVisible() {
      return this.visible;
    }
    setBorderRadius(radius: number) {
      this.borderRadius = radius;
    }
    setBounds(bounds: SurfaceBounds) {
      this.bounds = bounds;
    }
    setVisible(visible: boolean) {
      this.visible = visible;
    }
  }
  return { View };
});
vi.mock("electron", () => electron);

import { clipBrowserSidebarView } from "../browser-sidebar-view";

describe("clipBrowserSidebarView", () => {
  it("rounds only the corners the page shares with the panel", () => {
    const page = Object.assign(new electron.View(), {
      setBackgroundColor: vi.fn(),
      webContents: {},
    });
    const view = clipBrowserSidebarView(
      page as unknown as Parameters<typeof clipBrowserSidebarView>[0]
    );
    const frame = view.nativeView as InstanceType<typeof electron.View>;
    const [clip] = frame.children;
    const bounds = { height: 600, width: 438, x: 801, y: 40 };
    const place = (bottomLeft: number, bottomRight: number) => {
      view.setCornerRadii?.({ bottomLeft, bottomRight, topLeft: 0, topRight: 0 });
      view.setBounds(bounds);
    };
    expect(frame.children).toEqual([clip]);
    expect(clip?.children).toEqual([page]);

    // The panel's bottom-right corner: the clip reaches past the page's top
    // and left edges, so its other three rounded corners miss the page; the
    // frame, the page's own bounds, cuts that reach, so it takes no presses
    // of the renderer beside the page (the sidebar's resize edge).
    place(0, 11);
    expect(clip?.borderRadius).toBe(11);
    expect(frame.bounds).toEqual(bounds);
    expect(clip?.bounds).toEqual({ height: 611, width: 449, x: -11, y: -11 });
    expect(page.bounds).toEqual({ height: 600, width: 438, x: 11, y: 11 });
    expect(view.getBounds()).toEqual(bounds);

    // A page across the panel's bottom: only the clip's top reaches past it.
    place(11, 11);
    expect(frame.bounds).toEqual(bounds);
    expect(clip?.bounds).toEqual({ height: 611, width: 438, x: 0, y: -11 });
    expect(page.bounds).toEqual({ height: 600, width: 438, x: 0, y: 11 });

    place(0, 0);
    expect(clip?.borderRadius).toBe(0);
    expect(frame.bounds).toEqual(bounds);
    expect(clip?.bounds).toEqual({ ...bounds, x: 0, y: 0 });
    expect(view.getBounds()).toEqual(bounds);

    view.setVisible(false);
    expect(frame.getVisible()).toBe(false);
  });
});

import { beforeEach, expect, it, vi } from "vitest";

const host = vi.hoisted(() => ({
  focused: true,
  events: new Map<string, () => void>(),
  setMenu: vi.fn(),
  build: vi.fn(),
}));
vi.mock("electron", () => ({
  app: {
    name: "Comma",
    on: (event: string, listener: () => void) => host.events.set(event, listener),
  },
  Menu: { buildFromTemplate: host.build, setApplicationMenu: host.setMenu },
  nativeImage: { createFromBuffer: () => ({ setTemplateImage() {} }) },
}));
import { installApplicationMenu } from "../application-menu";
import {
  ApplicationMenuProvider,
  applicationMenuProvider,
} from "../application-menu-provider";

beforeEach(() => {
  vi.clearAllMocks();
  host.focused = true;
  host.events.clear();
  host.build.mockImplementation((template) => {
    const items = new Map();
    const collect = (entries: Array<Record<string, unknown>>) => {
      for (const item of entries) {
        if (item.id) items.set(item.id, { type: "normal", ...item });
        if (Array.isArray(item.submenu)) collect(item.submenu);
      }
    };
    collect(template);
    return { getMenuItemById: (id: string) => items.get(id) };
  });
});

it("preserves the installed menu while route commands and focus change", () => {
  const dispatch = vi.fn();
  installApplicationMenu({
    isMainFocused: () => host.focused,
    dispatch,
    openMain: vi.fn(),
    openSideChat: vi.fn(),
  });
  const menu = host.setMenu.mock.calls[0]![0];
  expect(menu.getMenuItemById("side-chat-background-debug")).toBeUndefined();
  applicationMenuProvider.update({
    locale: "en",
    items: [
      { id: "toggle-right-sidebar", enabled: true, checked: true },
      { id: "go-inbox", enabled: true },
    ],
  });
  expect(menu.getMenuItemById("toggle-right-sidebar")).toMatchObject({
    enabled: true,
    checked: true,
    type: "checkbox",
  });
  menu.getMenuItemById("go-inbox").click();
  expect(dispatch).toHaveBeenCalledWith("go-inbox");
  host.focused = false;
  host.events.get("browser-window-blur")!();
  expect(menu.getMenuItemById("go-inbox").enabled).toBe(false);
  host.focused = true;
  host.events.get("browser-window-focus")!();
  expect(menu.getMenuItemById("go-inbox").enabled).toBe(true);
  expect(host.setMenu).toHaveBeenCalledTimes(1);
  applicationMenuProvider.update({ locale: "zh-CN", items: [] });
  expect(host.setMenu).toHaveBeenCalledTimes(2);
});

it("opens Side Chat background controls from the development menu", () => {
  const openSideChatBackground = vi.fn();
  installApplicationMenu({
    isMainFocused: () => false,
    dispatch: vi.fn(),
    openMain: vi.fn(),
    openSideChat: vi.fn(),
    openSideChatBackground,
  });
  const menu = host.setMenu.mock.calls[0]![0];
  menu.getMenuItemById("side-chat-background-debug").click();
  expect(openSideChatBackground).toHaveBeenCalledOnce();
});

const settingsPresentation = (accelerator: string) => ({
  locale: "en" as const,
  items: [{ id: "go-settings" as const, enabled: true, accelerator }],
});

it("replays the latest presentation to a later menu, then follows updates", () => {
  const provider = new ApplicationMenuProvider();
  provider.update(settingsPresentation("Super+,"));
  const seen: Array<string | undefined> = [];
  const stop = provider.subscribe(({ items }) => seen.push(items[0]?.accelerator));
  provider.update(settingsPresentation("Control+Shift+S"));
  stop();
  provider.update(settingsPresentation("Alt+S"));

  expect(seen).toEqual(["Super+,", "Control+Shift+S"]);
});

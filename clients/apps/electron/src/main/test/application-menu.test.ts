import { beforeEach, expect, it, vi } from "vitest";

const host = vi.hoisted(() => ({
  focused: true,
  events: new Map<string, (...args: never[]) => void>(),
  setMenu: vi.fn(),
  build: vi.fn(),
}));
vi.mock("electron", () => ({
  app: {
    name: "Comma",
    on: (event: string, listener: (...args: never[]) => void) =>
      host.events.set(event, listener),
  },
  Menu: { buildFromTemplate: host.build, setApplicationMenu: host.setMenu },
  nativeImage: { createFromBuffer: () => ({ setTemplateImage() {} }) },
}));
import { installApplicationMenu, sidebarTabCommand } from "../application-menu";
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
  });
  const menu = host.setMenu.mock.calls[0]![0];
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
  (host.events.get("browser-window-blur") as () => void)();
  expect(menu.getMenuItemById("go-inbox").enabled).toBe(false);
  host.focused = true;
  (host.events.get("browser-window-focus") as () => void)();
  expect(menu.getMenuItemById("go-inbox").enabled).toBe(true);
  expect(host.setMenu).toHaveBeenCalledTimes(1);
  applicationMenuProvider.update({ locale: "zh-CN", items: [] });
  expect(host.setMenu).toHaveBeenCalledTimes(2);
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

const key = (input: Partial<Parameters<typeof sidebarTabCommand>[0]>) => ({
  type: "keyDown",
  key: "",
  control: false,
  meta: false,
  alt: false,
  shift: false,
  ...input,
});

it("reads ⌃Tab, ⌃⇧Tab and the platform's close-tab key as the sidebar's tab commands", () => {
  expect(sidebarTabCommand(key({ key: "Tab", control: true }), "darwin")).toBe(
    "browser-next-tab"
  );
  expect(
    sidebarTabCommand(key({ key: "Tab", control: true, shift: true }), "darwin")
  ).toBe("browser-previous-tab");
  expect(sidebarTabCommand(key({ key: "w", meta: true }), "darwin")).toBe(
    "browser-close-tab"
  );
  expect(sidebarTabCommand(key({ key: "w", control: true }), "win32")).toBe(
    "browser-close-tab"
  );
  // ⌃W is not macOS's close key, ⇧⌘W closes the window, and a key up is no press.
  expect(sidebarTabCommand(key({ key: "w", control: true }), "darwin")).toBeUndefined();
  expect(
    sidebarTabCommand(key({ key: "W", meta: true, shift: true }), "darwin")
  ).toBeUndefined();
  expect(
    sidebarTabCommand(key({ key: "Tab", control: true, type: "keyUp" }), "darwin")
  ).toBeUndefined();
});

it("takes a tab key from any page in the main window only while the sidebar can act on it", () => {
  const dispatch = vi.fn();
  installApplicationMenu({
    isMainFocused: () => host.focused,
    dispatch,
    openMain: vi.fn(),
  });
  let onInput: ((event: { preventDefault(): void }, input: object) => void) | undefined;
  (
    host.events.get("web-contents-created") as (
      event: unknown,
      contents: unknown
    ) => void
  )({}, { on: (_event: string, listener: typeof onInput) => (onInput = listener) });
  const press = (input: object) => {
    const event = { preventDefault: vi.fn() };
    onInput!(event, input);
    return event.preventDefault.mock.calls.length > 0;
  };
  const nextTab = key({ key: "Tab", control: true });

  // With no tab to act on, the key goes on to the page and the menu: ⌘W closes the window.
  applicationMenuProvider.update({
    locale: "en",
    items: [{ id: "browser-next-tab", enabled: false }],
  });
  expect(press(nextTab)).toBe(false);

  applicationMenuProvider.update({
    locale: "en",
    items: [{ id: "browser-next-tab", enabled: true }],
  });
  expect(press(nextTab)).toBe(true);
  expect(dispatch).toHaveBeenCalledWith("browser-next-tab");

  // Another window's key is its own.
  dispatch.mockClear();
  host.focused = false;
  expect(press(nextTab)).toBe(false);
  expect(dispatch).not.toHaveBeenCalled();
});

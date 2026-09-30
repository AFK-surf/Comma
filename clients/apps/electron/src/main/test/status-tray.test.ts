import {
  defaultAppPreferences,
  defaultCommaClientSettings,
  type AppPreferences,
  type ProductInboxItem,
} from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import { describe, expect, it, vi } from "vitest";
import type { ProductInboxStateEnvelope } from "../modules/product-inbox";
import {
  StatusTrayRecentTasks,
  createCommaStatusTray,
  createCommaStatusTrayIcon,
  recentStatusTrayTasks,
  statusTrayAccelerators,
  statusTrayTaskRoute,
  type StatusTrayContent,
  type StatusTrayMenuItem,
  type StatusTrayTask,
} from "../status-tray";

describe("createCommaStatusTrayIcon", () => {
  it("loads the transparent Comma Center template asset without runtime SVG rasterization", () => {
    const icon = {
      resize: vi.fn(),
      setTemplateImage: vi.fn(),
    };
    const createFromPath = vi.fn((_path: string) => icon);

    const result = createCommaStatusTrayIcon({
      iconPath: "/resources/CommaTemplate.png",
      nativeImage: { createFromPath },
      platform: "darwin",
    });

    expect(result).toBe(icon);
    expect(createFromPath).toHaveBeenCalledWith("/resources/CommaTemplate.png");
    expect(icon.resize).not.toHaveBeenCalled();
    expect(icon.setTemplateImage).toHaveBeenCalledWith(true);
  });
});

const task = (id: string, title = `Task ${id}`): StatusTrayTask => ({
  conversationId: `cnv_${id}`,
  groupId: "grp_1",
  title,
  workspaceId: "wsp_1",
});

function trayHarness(
  content: StatusTrayContent,
  {
    locale,
    measureMenuText,
  }: { locale?: "zh-CN"; measureMenuText?: (text: string) => number | null } = {}
) {
  const tray = {
    destroy: vi.fn(),
    setContextMenu: vi.fn(),
    setToolTip: vi.fn(),
  };
  const menus: Array<{
    items: StatusTrayMenuItem[];
    emit(event: "menu-will-close" | "menu-will-show"): void;
  }> = [];
  const scheduled: Array<() => void> = [];
  const handlers = {
    onOpenMainApp: vi.fn(),
    onOpenSettings: vi.fn(),
    onOpenSideChat: vi.fn(),
    onOpenTask: vi.fn(),
  };
  const controller = createCommaStatusTray({
    buildMenu: (items) => {
      const listeners = new Map<string, () => void>();
      const menu = {
        items,
        emit: (event: string) => listeners.get(event)?.(),
        on: (event: string, listener: () => void) => listeners.set(event, listener),
      };
      menus.push(menu);
      return menu;
    },
    content,
    createTray: () => tray,
    icon: "tray-icon",
    ...(locale ? { locale } : {}),
    ...(measureMenuText ? { measureMenuText } : {}),
    ...handlers,
    productName: "Comma",
    schedule: (run) => scheduled.push(run),
  });
  const rows = () =>
    menus
      .at(-1)!
      .items.map((item) =>
        item.type === "separator"
          ? "---"
          : item.type === "header"
            ? `# ${item.label}`
            : item.accelerator
              ? `${item.label} [${item.accelerator}]`
              : item.label
      );
  const flush = () => scheduled.splice(0).forEach((run) => run());
  return { controller, flush, handlers, menus, rows, tray };
}

describe("createCommaStatusTray", () => {
  it("shows the global shortcuts beside Open rows and the recent Tasks in their own section", () => {
    const { handlers, menus, rows, tray } = trayHarness({
      openCommaAccelerator: "Alt+Space",
      recentTasks: [task("1", "Draft Q3 plan & budget"), task("2")],
      settingsAccelerator: "Super+,",
      sideChatAccelerator: "Control+Z",
    });

    expect(tray.setToolTip).toHaveBeenCalledWith("Comma is running");
    expect(rows()).toEqual([
      "Open Comma [Alt+Space]",
      "Open Side Chat [Control+Z]",
      "---",
      "# Tasks",
      // "&&" renders as one "&"; a single one would be read as a mnemonic.
      "Draft Q3 plan && budget",
      "Task 2",
      "---",
      "Settings... [Super+,]",
      "---",
      "Quit Comma",
    ]);
    const items = menus[0]!.items;
    expect(items[0]?.registerAccelerator).toBe(false);
    expect(items[3]).toMatchObject({ enabled: false, type: "header" });
    expect(items.at(-1)?.role).toBe("quit");

    items[0]?.click?.();
    items[1]?.click?.();
    items[5]?.click?.();
    items[7]?.click?.();
    expect(handlers.onOpenMainApp).toHaveBeenCalledOnce();
    expect(handlers.onOpenSideChat).toHaveBeenCalledOnce();
    expect(handlers.onOpenTask).toHaveBeenCalledWith(task("2"));
    expect(handlers.onOpenSettings).toHaveBeenCalledOnce();
  });

  it("omits the Task section and unset shortcuts, in Simplified Chinese too", () => {
    const { rows, tray } = trayHarness({ recentTasks: [] }, { locale: "zh-CN" });

    expect(tray.setToolTip).toHaveBeenCalledWith("Comma 正在运行");
    expect(rows()).toEqual([
      "打开 Comma",
      "打开侧边聊天",
      "---",
      "设置...",
      "---",
      "退出 Comma",
    ]);
  });

  it("ends every long Task title at one measured edge of the menu font", () => {
    // A stand-in font: every glyph, "…" included, is 10 pt wide.
    const measureMenuText = vi.fn((text: string) => [...text].length * 10);
    const { rows } = trayHarness(
      {
        recentTasks: [
          task("long", "Summarize every customer interview from last week"),
          task("short", "Fix login"),
        ],
      },
      { measureMenuText }
    );

    // 170 pt holds 16 glyphs with the "…"; the cut drops the trailing space.
    expect(rows().slice(4, 6)).toEqual(["Summarize every…", "Fix login"]);
    expect(measureMenuText).toHaveBeenCalledWith("Summarize every c…");
  });

  it("approximates the menu font where Main cannot measure it", () => {
    const { rows } = trayHarness(
      {
        recentTasks: [
          task("en", "Summarize every customer interview from last week into themes"),
          task("zh", "整理上周所有客户访谈并按主题归纳成一份可以直接分享的报告"),
        ],
      },
      { measureMenuText: () => null }
    );

    expect(rows().slice(4, 6)).toEqual([
      "Summarize every customer…",
      "整理上周所有客户访谈并按…",
    ]);
  });

  it("names a Task without a title instead of showing an empty row", () => {
    const { rows } = trayHarness({ recentTasks: [task("blank", "  ")] });

    expect(rows()[4]).toBe("Untitled Task");
  });

  it("installs a customized shortcut, but never swaps the menu while it is open", () => {
    const { controller, flush, menus, rows, tray } = trayHarness({
      openCommaAccelerator: "Alt+Space",
      recentTasks: [task("1")],
    });

    controller.update({ openCommaAccelerator: "Alt+Space", recentTasks: [task("1")] });
    expect(tray.setContextMenu).toHaveBeenCalledTimes(1);

    menus[0]!.emit("menu-will-show");
    controller.update({
      openCommaAccelerator: "Control+Shift+K",
      recentTasks: [task("2"), task("1")],
    });
    expect(tray.setContextMenu).toHaveBeenCalledTimes(1);

    // The chosen row's click lands after close; the swap waits one task more.
    menus[0]!.emit("menu-will-close");
    expect(tray.setContextMenu).toHaveBeenCalledTimes(1);
    flush();
    expect(tray.setContextMenu).toHaveBeenCalledTimes(2);
    expect(rows().slice(0, 6)).toEqual([
      "Open Comma [Control+Shift+K]",
      "Open Side Chat",
      "---",
      "# Tasks",
      "Task 2",
      "Task 1",
    ]);

    controller.destroy();
    controller.update({ recentTasks: [] });
    flush();
    expect(tray.destroy).toHaveBeenCalledOnce();
    expect(tray.setContextMenu).toHaveBeenCalledTimes(2);
  });
});

const item = (
  id: string,
  updatedAt: number,
  overrides: Partial<ProductInboxItem> = {}
) =>
  ({
    conversationId: `cnv_${id}`,
    groupId: "grp_1",
    id: `item_${id}`,
    kind: "agent_task",
    source: "salix.conversation",
    status: "active",
    title: `Task ${id}`,
    updatedAt,
    workspaceId: "wsp_1",
    workspaceName: "Personal",
    ...overrides,
  }) satisfies ProductInboxItem;

const preferences = (overrides: Partial<AppPreferences>): AppPreferences => ({
  ...defaultAppPreferences,
  clientSettings: {
    ...defaultCommaClientSettings,
    openCommaShortcut: {
      key: "k",
      modifiers: { alt: false, control: true, meta: true, shift: false },
    },
    sideChatShortcut: {
      key: "space",
      modifiers: { alt: false, control: false, meta: false, shift: true },
    },
  },
  ...overrides,
});

const lease = (generation: number): SessionProductLease => ({
  audience: "https://api.comma.test",
  authorityInstanceId: "main",
  generation,
  sessionId: "ses_1",
});

const envelope = (
  session: SessionProductLease,
  items: ProductInboxItem[]
): ProductInboxStateEnvelope => ({
  session,
  snapshot: { items, source: "live-sync" },
});

describe("recentStatusTrayTasks", () => {
  it("lists the five most recently updated unarchived Tasks", () => {
    const tasks = recentStatusTrayTasks([
      item("chat", 900, { kind: "user_chat" }),
      item("archived", 800, { status: "archived" }),
      ...[1, 7, 3, 6, 2, 5].map((n) => item(String(n), n)),
    ]);

    expect(tasks.map(({ title }) => title)).toEqual([
      "Task 7",
      "Task 6",
      "Task 5",
      "Task 3",
      "Task 2",
    ]);
  });
});

describe("statusTrayAccelerators", () => {
  it("follows the customized chords that are actually registered", () => {
    expect(
      statusTrayAccelerators(
        preferences({ openCommaShortcutStatus: "registered" }),
        "macos"
      )
    ).toEqual({
      openCommaAccelerator: "Control+Super+K",
      sideChatAccelerator: "Shift+Space",
    });
    expect(
      statusTrayAccelerators(
        preferences({ openCommaShortcutStatus: "unavailable" }),
        "windows"
      )
    ).toEqual({ openCommaAccelerator: undefined, sideChatAccelerator: undefined });
  });
});

describe("StatusTrayRecentTasks", () => {
  it("holds one subscription per session and clears the list when it stops", () => {
    const unsubscribe = vi.fn();
    const listeners: Array<(envelope: ProductInboxStateEnvelope) => void> = [];
    const subscribe = vi.fn(
      (
        _session: SessionProductLease,
        listener: (value: ProductInboxStateEnvelope) => void
      ) => {
        listeners.push(listener);
        return unsubscribe;
      }
    );
    const onChanged = vi.fn();
    const recent = new StatusTrayRecentTasks({ onChanged, subscribe });

    recent.follow(lease(1));
    recent.follow(lease(1));
    expect(subscribe).toHaveBeenCalledOnce();

    listeners[0]!(envelope(lease(1), [item("1", 1)]));
    listeners[0]!(envelope(lease(1), [item("1", 1)]));
    expect(onChanged).toHaveBeenCalledOnce();
    expect(recent.tasks).toEqual([task("1")]);

    recent.follow(lease(2));
    expect(unsubscribe).toHaveBeenCalledOnce();
    expect(subscribe).toHaveBeenCalledTimes(2);

    recent.follow(undefined);
    expect(unsubscribe).toHaveBeenCalledTimes(2);
    expect(recent.tasks).toEqual([]);
    expect(onChanged).toHaveBeenLastCalledWith([]);
  });
});

describe("statusTrayTaskRoute", () => {
  it("opens the Task at the route the ⌘K palette uses", () => {
    expect(statusTrayTaskRoute(task("1"))).toBe("/tasks/wsp_1/grp_1/cnv_1");
  });
});

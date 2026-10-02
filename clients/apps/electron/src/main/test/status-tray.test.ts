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
  StatusTrayInProgressTasks,
  createCommaStatusTray,
  createCommaStatusTrayIcon,
  electronStatusTrayHost,
  fallbackStatusTrayHost,
  helperStatusTrayHost,
  inProgressStatusTrayTasks,
  statusTrayPreferenceContent,
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

const trayHandlers = () => ({
  onOpenMainApp: vi.fn(),
  onOpenSettings: vi.fn(),
  onOpenSideChat: vi.fn(),
  onOpenTask: vi.fn(),
  onOpenTasks: vi.fn(),
});

// The menu Electron draws: Windows and Linux, and macOS without the addon.
function trayHarness(
  content: StatusTrayContent,
  { locale }: { locale?: "zh-CN" } = {}
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
  const handlers = trayHandlers();
  const controller = createCommaStatusTray({
    content,
    createHost: (toolTip) =>
      electronStatusTrayHost({
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
        createTray: () => tray,
        schedule: (run) => scheduled.push(run),
        toolTip,
      }),
    ...(locale ? { locale } : {}),
    ...handlers,
    productName: "Comma",
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
  it("shows the global shortcuts beside Open rows and the In progress Tasks in their own section", () => {
    const { handlers, menus, rows, tray } = trayHarness({
      openCommaAccelerator: "Alt+Space",
      inProgressTasks: [task("1", "Draft Q3 plan & budget"), task("2")],
      settingsAccelerator: "Super+,",
      sideChatAccelerator: "Control+Z",
    });

    expect(tray.setToolTip).toHaveBeenCalledWith("Comma is running");
    expect(rows()).toEqual([
      "Open Comma [Alt+Space]",
      "Open Side Chat [Control+Z]",
      "---",
      "# In progress",
      // "&&" renders as one "&"; a single one would be read as a mnemonic.
      "Draft Q3 plan && budget",
      "Task 2",
      // The whole list is one click away.
      "More...",
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
    items[6]?.click?.();
    items[8]?.click?.();
    expect(handlers.onOpenMainApp).toHaveBeenCalledOnce();
    expect(handlers.onOpenSideChat).toHaveBeenCalledOnce();
    expect(handlers.onOpenTask).toHaveBeenCalledWith(task("2"));
    expect(handlers.onOpenTasks).toHaveBeenCalledOnce();
    expect(handlers.onOpenSettings).toHaveBeenCalledOnce();
  });

  it("omits the Task section without an In progress Task, and unset shortcuts, in Simplified Chinese too", () => {
    const { rows, tray } = trayHarness({ inProgressTasks: [] }, { locale: "zh-CN" });

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

  it("switches its rows when the app language changes", () => {
    const { controller, rows } = trayHarness({ inProgressTasks: [] });
    expect(rows()[0]).toBe("Open Comma");

    controller.update({ inProgressTasks: [], locale: "zh-CN" });

    expect(rows()[0]).toBe("打开 Comma");
  });

  it("ends a long Task title where the menu Electron draws keeps it", () => {
    const { rows } = trayHarness({
      inProgressTasks: [
        task("en", "Summarize every customer interview from last week into themes"),
        task("zh", "整理上周所有客户访谈并按主题归纳成一份可以直接分享的报告"),
      ],
    });

    expect(rows().slice(4, 6)).toEqual([
      "Summarize every customer…",
      "整理上周所有客户访谈并按…",
    ]);
  });

  it("names a Task without a title instead of showing an empty row", () => {
    const { rows } = trayHarness({ inProgressTasks: [task("blank", "  ")] });

    expect(rows()[4]).toBe("Untitled Task");
  });

  it("installs a customized shortcut, but never swaps the menu while it is open", () => {
    const { controller, flush, menus, rows, tray } = trayHarness({
      openCommaAccelerator: "Alt+Space",
      inProgressTasks: [task("1")],
    });

    controller.update({
      openCommaAccelerator: "Alt+Space",
      inProgressTasks: [task("1")],
    });
    expect(tray.setContextMenu).toHaveBeenCalledTimes(1);

    menus[0]!.emit("menu-will-show");
    controller.update({
      openCommaAccelerator: "Control+Shift+K",
      inProgressTasks: [task("2"), task("1")],
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
      "# In progress",
      "Task 2",
      "Task 1",
    ]);

    controller.destroy();
    controller.update({ inProgressTasks: [] });
    flush();
    expect(tray.destroy).toHaveBeenCalledOnce();
    expect(tray.setContextMenu).toHaveBeenCalledTimes(2);
  });
});

describe("helperStatusTrayHost", () => {
  function helperHarness(content: StatusTrayContent) {
    const helper = { hideStatusMenu: vi.fn(), showStatusMenu: vi.fn() };
    const onQuit = vi.fn();
    const handlers = trayHandlers();
    const controller = createCommaStatusTray({
      content,
      createHost: (toolTip) =>
        helperStatusTrayHost({
          helper,
          iconPath: "/resources/CommaTemplate.png",
          onLost: vi.fn(),
          onQuit,
          toolTip,
        }),
      ...handlers,
      productName: "Comma",
    });
    const select = (id: string) =>
      (helper.showStatusMenu.mock.lastCall![1] as (selected: string) => void)(id);
    return { controller, handlers, helper, onQuit, select };
  }

  it("sends whole titles at the menu width, with each chord as macOS shows it", () => {
    const { helper } = helperHarness({
      openCommaAccelerator: "Control+Alt+Shift+7",
      inProgressTasks: [
        task("1", "Summarize every customer interview from last week & plan"),
      ],
      settingsAccelerator: "Super+Alt+J",
      sideChatAccelerator: "Control+Space",
    });

    expect(helper.showStatusMenu).toHaveBeenCalledWith(
      {
        iconPath: "/resources/CommaTemplate.png",
        rows: [
          { id: "open-comma", kind: "item", title: "Open Comma", shortcut: "⌃⌥⇧ 7" },
          {
            id: "open-side-chat",
            kind: "item",
            title: "Open Side Chat",
            shortcut: "⌃ Space",
          },
          { kind: "separator" },
          { kind: "header", title: "In progress" },
          // The helper ends a long title at the right edge; "&" is no mnemonic here.
          {
            id: "task:grp_1/cnv_1",
            kind: "item",
            title: "Summarize every customer interview from last week & plan",
          },
          { id: "more-tasks", kind: "item", title: "More..." },
          { kind: "separator" },
          { id: "settings", kind: "item", title: "Settings...", shortcut: "⌥⌘ J" },
          { kind: "separator" },
          { id: "quit", kind: "item", title: "Quit Comma", shortcut: "⌘ Q" },
        ],
        toolTip: "Comma is running",
        width: 260,
      },
      expect.any(Function),
      expect.any(Function)
    );
  });

  it("drops Open Side Chat while Side Chat is off and restores it when turned on", () => {
    const { controller, helper } = helperHarness({
      inProgressTasks: [],
      sideChatEnabled: false,
    });
    const rowIds = () =>
      (helper.showStatusMenu.mock.lastCall![0] as { rows: Array<{ id?: string }> }).rows
        .map((row) => row.id)
        .filter(Boolean);

    expect(rowIds()).toEqual(["open-comma", "settings", "quit"]);
    controller.update({ inProgressTasks: [], sideChatEnabled: true });
    expect(rowIds()).toEqual(["open-comma", "open-side-chat", "settings", "quit"]);
  });

  it("runs a chosen row's click, also for a row an update replaced while the menu was open", () => {
    const { controller, handlers, helper, onQuit, select } = helperHarness({
      inProgressTasks: [task("1")],
    });

    select("settings");
    expect(handlers.onOpenSettings).toHaveBeenCalledOnce();
    select("quit");
    expect(onQuit).toHaveBeenCalledOnce();

    // The helper keeps the open menu's rows until it closes.
    controller.update({ inProgressTasks: [task("2")] });
    select("task:grp_1/cnv_1");
    expect(handlers.onOpenTask).toHaveBeenCalledWith(task("1"));

    controller.destroy();
    expect(helper.hideStatusMenu).toHaveBeenCalledOnce();
  });
});

describe("fallbackStatusTrayHost", () => {
  it("draws the menu with Electron for good once the helper loses it", () => {
    const helper = { hideStatusMenu: vi.fn(), showStatusMenu: vi.fn() };
    const tray = { destroy: vi.fn(), setContextMenu: vi.fn(), setToolTip: vi.fn() };
    const menus: StatusTrayMenuItem[][] = [];
    const handlers = trayHandlers();
    const longTitle =
      "Summarize every customer interview from last week & plan the follow-ups";
    const controller = createCommaStatusTray({
      content: { inProgressTasks: [task("1", longTitle)] },
      createHost: (toolTip, reinstall) =>
        fallbackStatusTrayHost({
          createFallback: () =>
            electronStatusTrayHost({
              buildMenu: (items) => {
                menus.push(items);
                return { on: vi.fn() };
              },
              createTray: () => tray,
              toolTip,
            }),
          createPrimary: (onLost) =>
            helperStatusTrayHost({
              helper,
              iconPath: "/resources/CommaTemplate.png",
              onLost,
              onQuit: vi.fn(),
              toolTip,
            }),
          reinstall,
        }),
      ...handlers,
      productName: "Comma",
    });
    expect(helper.showStatusMenu).toHaveBeenCalledOnce();
    expect(menus).toEqual([]);

    const onLost = helper.showStatusMenu.mock.lastCall![2] as () => void;
    onLost();
    // The rows come again, labeled for the menu Electron draws.
    expect(tray.setToolTip).toHaveBeenCalledWith("Comma is running");
    const taskRow = menus.at(-1)!.find(({ id }) => id === "task:grp_1/cnv_1")!;
    expect(taskRow.label).toMatch(/…$/);
    taskRow.click!();
    expect(handlers.onOpenTask).toHaveBeenCalledWith(task("1", longTitle));

    onLost();
    controller.update({ inProgressTasks: [task("2")] });
    expect(helper.showStatusMenu).toHaveBeenCalledOnce();
    expect(menus).toHaveLength(2);

    controller.destroy();
    expect(tray.destroy).toHaveBeenCalledOnce();
    expect(helper.hideStatusMenu).not.toHaveBeenCalled();
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

describe("inProgressStatusTrayTasks", () => {
  it("lists the five most recently updated Tasks in the In progress column", () => {
    const tasks = inProgressStatusTrayTasks([
      item("chat", 900, { kind: "user_chat" }),
      item("review", 800, { status: "ready_for_review" }),
      item("done", 700, { status: "completed" }),
      item("queued", 600, { status: "queued" }),
      item("archived", 500, { status: "archived" }),
      item("running", 8, { status: "running" }),
      ...[1, 7, 3, 6, 2, 5].map((n) => item(String(n), n)),
    ]);

    expect(tasks.map(({ title }) => title)).toEqual([
      "Task running",
      "Task 7",
      "Task 6",
      "Task 5",
      "Task 3",
    ]);
  });
});

describe("statusTrayPreferenceContent", () => {
  it("follows the customized chords that are actually registered", () => {
    expect(
      statusTrayPreferenceContent(
        preferences({ openCommaShortcutStatus: "registered" }),
        "macos"
      )
    ).toEqual({
      openCommaAccelerator: "Control+Super+K",
      sideChatAccelerator: "Shift+Space",
      sideChatEnabled: true,
    });
    expect(
      statusTrayPreferenceContent(
        preferences({ openCommaShortcutStatus: "unavailable", sideChatEnabled: false }),
        "windows"
      )
    ).toEqual({
      openCommaAccelerator: undefined,
      sideChatAccelerator: undefined,
      sideChatEnabled: false,
    });
  });
});

describe("StatusTrayInProgressTasks", () => {
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
    const recent = new StatusTrayInProgressTasks({ onChanged, subscribe });

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

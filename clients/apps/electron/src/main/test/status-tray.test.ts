import {
  defaultAppPreferences,
  defaultCommaClientSettings,
  type AppPreferences,
} from "@comma/native-bridge";
import type { StatusMenuRow } from "@comma/chat-contract";
import type { ProductInboxItem, ProductInboxListResult } from "@comma/core/contract";
import type { SessionProductLease } from "@comma/session-contract";
import { describe, expect, it, vi } from "vitest";
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
import type { StatusTrayUsageSnapshot } from "../status-tray-usage";

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
  onOpenTask: vi.fn(),
  onOpenTasks: vi.fn(),
  onOpenUsageSettings: vi.fn(),
  onMenuOpened: vi.fn(),
  onQuickChat: vi.fn(),
  onRefreshUsage: vi.fn(),
});

/** Electron's Tray: the left and right clicks it reports, and the menu it pops up. */
function fakeTray() {
  const listeners = new Map<string, (event?: { ctrlKey?: boolean }) => void>();
  return {
    destroy: vi.fn(),
    emit: (event: "click" | "right-click", details?: { ctrlKey?: boolean }) =>
      listeners.get(event)?.(details),
    on: (event: string, listener: (event?: { ctrlKey?: boolean }) => void) =>
      listeners.set(event, listener),
    popUpContextMenu: vi.fn(),
    setContextMenu: vi.fn(),
    setToolTip: vi.fn(),
  };
}

// Comma Pro with 6% of its credits used, and a Claude Max plan.
const start = Date.parse("2026-10-13T08:00:00Z");
const usage: StatusTrayUsageSnapshot = {
  comma: {
    credits: 9_000,
    plan: "Comma Pro",
    status: "ready",
    unlimited: false,
    usage: {
      ends: false,
      otherCredits: 1_500,
      resetsAt: "2026-10-13T11:00:00Z",
      usedPercent: 6.4,
    },
  },
  accounts: [
    {
      id: "pro_1",
      meters: [
        { percent: 94, resetAt: "2026-10-13T11:00:00Z", window: "5h" },
        { percent: 5, resetAt: "2026-10-17T08:00:00Z", window: "week" },
      ],
      name: "Work",
      plan: "max",
      provider: "Claude",
    },
  ],
  refresh: { state: "idle", updatedAt: start - 30_000 },
};

// The menu Electron draws: Windows and Linux, and macOS without the addon.
function trayHarness(
  content: StatusTrayContent,
  {
    locale,
    now,
    platform = "linux",
  }: { locale?: "zh-CN"; now?: () => number; platform?: NodeJS.Platform } = {}
) {
  const tray = fakeTray();
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
        platform,
        schedule: (run) => scheduled.push(run),
        toolTip,
      }),
    ...(locale ? { locale } : {}),
    ...handlers,
    ...(now ? { now } : {}),
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
    });

    expect(tray.setToolTip).toHaveBeenCalledWith("Comma is running");
    expect(rows()).toEqual([
      "Open Comma [Alt+Space]",
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
    expect(items[2]).toMatchObject({ enabled: false, type: "header" });
    expect(items.at(-1)?.role).toBe("quit");

    items[0]?.click?.();
    items[4]?.click?.();
    items[5]?.click?.();
    items[7]?.click?.();
    expect(handlers.onOpenMainApp).toHaveBeenCalledOnce();
    expect(handlers.onOpenTask).toHaveBeenCalledWith(task("2"));
    expect(handlers.onOpenTasks).toHaveBeenCalledOnce();
    expect(handlers.onOpenSettings).toHaveBeenCalledOnce();
  });

  it("omits the Task section without an In progress Task, and unset shortcuts, in Simplified Chinese too", () => {
    const { rows, tray } = trayHarness({ inProgressTasks: [] }, { locale: "zh-CN" });

    expect(tray.setToolTip).toHaveBeenCalledWith("Comma 正在运行");
    expect(rows()).toEqual(["打开 Comma", "---", "设置...", "---", "退出 Comma"]);
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

    expect(rows().slice(3, 5)).toEqual([
      "Summarize every customer…",
      "整理上周所有客户访谈并按…",
    ]);
  });

  it("names a Task without a title instead of showing an empty row", () => {
    const { rows } = trayHarness({ inProgressTasks: [task("blank", "  ")] });

    expect(rows()[3]).toBe("Untitled Task");
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
    expect(rows().slice(0, 5)).toEqual([
      "Open Comma [Control+Shift+K]",
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

describe("electronStatusTrayHost", () => {
  it("pops the menu up on macOS with its times said from then, and leaves the left click to Quick Chat", () => {
    let time = start;
    const { controller, handlers, menus, tray } = trayHarness(
      { inProgressTasks: [], quickChat: true, usage },
      { now: () => time, platform: "darwin" }
    );
    const refreshed = () =>
      menus.at(-1)!.items.find((item) => item.id === "usage:refresh");
    expect(tray.setContextMenu).toHaveBeenLastCalledWith(null);
    tray.emit("click");
    expect(handlers.onQuickChat).toHaveBeenCalledOnce();

    time += 2 * 60 * 60_000;
    tray.emit("right-click");
    expect(handlers.onMenuOpened).toHaveBeenCalledOnce();
    expect(tray.popUpContextMenu).toHaveBeenLastCalledWith(menus.at(-1));
    expect(refreshed()?.label).toBe("Refresh · Updated 2h ago");
    // Control-click is a right click.
    tray.emit("click", { ctrlKey: true });
    expect(tray.popUpContextMenu).toHaveBeenCalledTimes(2);
    expect(handlers.onQuickChat).toHaveBeenCalledOnce();

    // Without Quick Chat a left click opens the menu, as a menu-bar item does.
    controller.update({ inProgressTasks: [], usage });
    tray.emit("click");
    expect(tray.popUpContextMenu).toHaveBeenCalledTimes(3);
    expect(tray.setContextMenu).not.toHaveBeenCalledWith(menus.at(-1));
  });

  it("pops the menu up on a right click on Windows; a left click opens nothing", () => {
    const { handlers, menus, tray } = trayHarness(
      { inProgressTasks: [] },
      { platform: "win32" }
    );
    tray.emit("click");
    expect(tray.popUpContextMenu).not.toHaveBeenCalled();
    tray.emit("right-click");
    expect(handlers.onMenuOpened).toHaveBeenCalledOnce();
    expect(tray.popUpContextMenu).toHaveBeenCalledWith(menus.at(-1));
  });

  it("on Linux sets the tray's context menu, unless a left click starts Quick Chat", () => {
    const { controller, handlers, menus, tray } = trayHarness({
      inProgressTasks: [],
      quickChat: true,
    });
    // Not the context menu, which the left click would open.
    expect(tray.setContextMenu).toHaveBeenLastCalledWith(null);
    tray.emit("click");
    expect(handlers.onQuickChat).toHaveBeenCalledOnce();
    tray.emit("right-click");
    expect(tray.popUpContextMenu).toHaveBeenCalledWith(menus.at(-1));
    // Control-click is a right click.
    tray.emit("click", { ctrlKey: true });
    expect(tray.popUpContextMenu).toHaveBeenCalledTimes(2);
    expect(handlers.onQuickChat).toHaveBeenCalledOnce();

    controller.update({ inProgressTasks: [], quickChat: false });
    expect(tray.setContextMenu).toHaveBeenLastCalledWith(menus.at(-1));
    tray.emit("click");
    tray.emit("right-click");
    expect(handlers.onQuickChat).toHaveBeenCalledOnce();
    expect(tray.popUpContextMenu).toHaveBeenCalledTimes(2);
    // The tray shows it, and it is told as it shows.
    const opened = handlers.onMenuOpened.mock.calls.length;
    menus.at(-1)!.emit("menu-will-show");
    expect(handlers.onMenuOpened).toHaveBeenCalledTimes(opened + 1);
  });
});

// The menu the menu-bar helper draws.
function helperHarness(
  content: StatusTrayContent,
  { now }: { now?: () => number } = {}
) {
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
    ...(now ? { now } : {}),
    productName: "Comma",
  });
  const select = (id: string) =>
    (helper.showStatusMenu.mock.lastCall![1] as (selected: string) => void)(id);
  return { controller, handlers, helper, onQuit, select };
}

describe("helperStatusTrayHost", () => {
  it("sends whole titles at the menu width, with each chord as macOS shows it", () => {
    const { helper } = helperHarness({
      openCommaAccelerator: "Control+Alt+Shift+7",
      inProgressTasks: [
        task("1", "Summarize every customer interview from last week & plan"),
      ],
      settingsAccelerator: "Super+Alt+J",
    });

    expect(helper.showStatusMenu).toHaveBeenCalledWith(
      {
        // The helper says when the menu opens (times are said from then) and
        // once it has closed.
        closeId: "status-menu:close",
        iconPath: "/resources/CommaTemplate.png",
        openId: "status-menu:open",
        rows: [
          { id: "open-comma", kind: "item", title: "Open Comma", shortcut: "⌃⌥⇧ 7" },
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

  it("runs a chosen row's click, also for a row an update replaced while the menu was open", () => {
    const { controller, handlers, helper, onQuit, select } = helperHarness({
      inProgressTasks: [task("1")],
    });

    select("settings");
    expect(handlers.onOpenSettings).toHaveBeenCalledOnce();
    select("quit");
    expect(onQuit).toHaveBeenCalledOnce();

    // The helper keeps the open menu's rows until it closes, however many
    // updates arrive meanwhile.
    select("status-menu:open");
    controller.update({ inProgressTasks: [task("2")] });
    controller.update({ inProgressTasks: [task("3")] });
    select("task:grp_1/cnv_1");
    expect(handlers.onOpenTask).toHaveBeenCalledWith(task("1"));

    // Closed, it shows the latest rows: the ones it showed before are let go.
    select("status-menu:close");
    controller.update({ inProgressTasks: [task("4")] });
    select("task:grp_1/cnv_1");
    expect(handlers.onOpenTask).toHaveBeenCalledOnce();

    controller.destroy();
    expect(helper.hideStatusMenu).toHaveBeenCalledOnce();
  });

  it("starts Quick Chat on a left click while it runs, and from its row, which shows its gesture", () => {
    const { controller, handlers, helper, select } = helperHarness({
      inProgressTasks: [],
      quickChat: true,
    });
    const shown = () =>
      helper.showStatusMenu.mock.lastCall![0] as {
        clickId?: string;
        rows: StatusMenuRow[];
      };

    select(shown().clickId!);
    expect(handlers.onQuickChat).toHaveBeenCalledOnce();
    expect(handlers.onOpenMainApp).not.toHaveBeenCalled();
    expect(shown().rows.slice(0, 2)).toEqual([
      { id: "open-comma", kind: "item", title: "Open Comma" },
      { id: "quick-chat", kind: "item", shortcut: "Double-tap ⌘", title: "Quick Chat" },
    ]);
    select("quick-chat");
    expect(handlers.onQuickChat).toHaveBeenCalledTimes(2);

    // Signed out, or its helper down: any click opens the menu again, and
    // Quick Chat has no row.
    controller.update({ inProgressTasks: [], quickChat: false });
    expect(shown().clickId).toBeUndefined();
    expect(shown().rows.some((row) => row.id === "quick-chat")).toBe(false);
  });
});

/** The rows between Open Comma and the separator above Settings. */
const usageRows = (rows: StatusMenuRow[]) =>
  rows.slice(
    rows.findIndex((row) => row.id === "open-comma") + 1,
    rows.findIndex((row) => row.id === "settings") - 1
  );

describe("the usage block", () => {
  it("shows Comma's credits and each signed-in plan as used percent with a bar, then Refresh", () => {
    let time = start;
    const { handlers, helper, select } = helperHarness(
      { inProgressTasks: [], usage },
      { now: () => time }
    );
    const rows = () =>
      usageRows(
        (helper.showStatusMenu.mock.lastCall![0] as { rows: StatusMenuRow[] }).rows
      );

    expect(rows()).toEqual([
      { kind: "separator" },
      { kind: "header", title: "Comma Pro" },
      {
        detail: "6% · resets 3h",
        fraction: 0.06,
        id: "usage:comma",
        kind: "meter",
        title: "Monthly credits",
        tone: "normal",
      },
      { detail: "1.5K left", id: "usage:extra", kind: "meter", title: "Extra credits" },
      { kind: "separator" },
      { kind: "header", title: "Claude · Max" },
      {
        detail: "6% · resets 3h",
        fraction: 0.06,
        id: "usage:pro_1:5h",
        kind: "meter",
        title: "5-hour limit",
        tone: "normal",
      },
      // Less than a tenth left draws the bar red.
      {
        detail: "95% · resets 4d",
        fraction: 0.95,
        id: "usage:pro_1:week",
        kind: "meter",
        title: "Weekly · all models",
        tone: "critical",
      },
      {
        detail: "Updated just now",
        id: "usage:refresh",
        kind: "item",
        title: "Refresh",
      },
      { id: "usage:settings", kind: "item", title: "Usage settings..." },
    ]);

    select("usage:refresh");
    expect(handlers.onRefreshUsage).toHaveBeenCalledOnce();
    select("usage:settings");
    expect(handlers.onOpenUsageSettings).toHaveBeenCalledOnce();

    // Opening the menu says the times from then, and may read the usage again.
    time += 2 * 60 * 60_000;
    select("status-menu:open");
    expect(handlers.onMenuOpened).toHaveBeenCalledOnce();
    expect(
      rows().filter((row) => row.kind !== "header" && row.kind !== "separator")
    ).toMatchObject([
      { detail: "6% · resets 1h" },
      { detail: "1.5K left" },
      { detail: "6% · resets 1h" },
      { detail: "95% · resets 4d" },
      { detail: "Updated 2h ago" },
      { id: "usage:settings" },
    ]);

    // Past a reset its figure is from before it: the row says it reset.
    time += 90 * 60_000;
    select("status-menu:open");
    expect(rows().find((row) => row.id === "usage:comma")).toEqual({
      detail: "Reset",
      id: "usage:comma",
      kind: "meter",
      title: "Monthly credits",
    });
    expect(rows().find((row) => row.id === "usage:pro_1:5h")).toMatchObject({
      detail: "Reset",
    });
  });

  it("shows the balance without a plan, and no usage while signed out", () => {
    const { controller, helper } = helperHarness({
      inProgressTasks: [],
      usage: {
        accounts: [],
        comma: {
          credits: 0,
          plan: null,
          status: "ready",
          unlimited: false,
          usage: null,
        },
        refresh: { state: "updating", updatedAt: null },
      },
    });
    const rows = () =>
      (helper.showStatusMenu.mock.lastCall![0] as { rows: StatusMenuRow[] }).rows;

    expect(usageRows(rows())).toEqual([
      { kind: "separator" },
      { kind: "header", title: "Comma usage" },
      { detail: "None left", id: "usage:comma", kind: "meter", title: "Credits" },
      { detail: "Updating…", id: "usage:refresh", kind: "item", title: "Refresh" },
      { id: "usage:settings", kind: "item", title: "Usage settings..." },
    ]);

    // A self-hosted instance's credits have no limit.
    controller.update({
      inProgressTasks: [],
      usage: {
        accounts: [],
        comma: {
          credits: 0,
          plan: null,
          status: "ready",
          unlimited: true,
          usage: null,
        },
        refresh: { state: "idle", updatedAt: null },
      },
    });
    expect(rows().find((row) => row.id === "usage:comma")?.detail).toBe("Unlimited");

    controller.update({ inProgressTasks: [] });
    expect(rows().some((row) => row.id?.startsWith("usage:"))).toBe(false);
  });

  it("shows a meter as a grey row with its figure after its title in the menu Electron draws", () => {
    const { menus } = trayHarness({ inProgressTasks: [], usage }, { now: () => start });
    expect(menus.at(-1)!.items.find((item) => item.id === "usage:pro_1:week")).toEqual({
      enabled: false,
      id: "usage:pro_1:week",
      label: "Weekly · all models · 95% · resets 4d",
    });
  });
});

describe("fallbackStatusTrayHost", () => {
  it("draws the menu with Electron for good once the helper loses it", () => {
    const helper = { hideStatusMenu: vi.fn(), showStatusMenu: vi.fn() };
    const tray = fakeTray();
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
  },
  ...overrides,
});

const lease = (generation: number): SessionProductLease => ({
  audience: "https://api.comma.test",
  authorityInstanceId: "main",
  generation,
  sessionId: "ses_1",
});

const list = (items: ProductInboxItem[]): ProductInboxListResult => ({
  items,
  source: "live-sync",
});

describe("inProgressStatusTrayTasks", () => {
  it("lists the five most recently updated Tasks in the In progress column", () => {
    const tasks = inProgressStatusTrayTasks([
      item("chat", 900, { kind: "user_chat" }),
      item("review", 800, { status: "ready_for_review" }),
      item("done", 700, { status: "completed" }),
      item("cancelled", 600, { status: "cancelled" }),
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
  it("follows the customized chord while it is actually registered", () => {
    expect(
      statusTrayPreferenceContent(
        preferences({ openCommaShortcutStatus: "registered" })
      )
    ).toEqual({ openCommaAccelerator: "Control+Super+K" });
    expect(
      statusTrayPreferenceContent(
        preferences({ openCommaShortcutStatus: "unavailable" })
      )
    ).toEqual({ openCommaAccelerator: undefined });
  });
});

describe("StatusTrayInProgressTasks", () => {
  it("holds one subscription per session and clears the list when it stops", () => {
    const unsubscribe = vi.fn();
    const listeners: Array<(value: ProductInboxListResult) => void> = [];
    const subscribe = vi.fn((listener: (value: ProductInboxListResult) => void) => {
      listeners.push(listener);
      return unsubscribe;
    });
    const onChanged = vi.fn();
    const recent = new StatusTrayInProgressTasks({ onChanged, subscribe });

    recent.follow(lease(1));
    recent.follow(lease(1));
    expect(subscribe).toHaveBeenCalledOnce();

    listeners[0]!(list([item("1", 1)]));
    listeners[0]!(list([item("1", 1)]));
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

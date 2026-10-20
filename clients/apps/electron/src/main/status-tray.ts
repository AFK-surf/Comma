import {
  baseLocale,
  formatNumber,
  formatRelativeTime,
  messages,
  taskStatusBucket,
  type CommaLocale,
} from "@comma/i18n";
import type { ProductInboxItem, ProductInboxListResult } from "@comma/core/contract";
import { defaultCommaClientSettings, type AppPreferences } from "@comma/native-bridge";
import {
  sameSessionProductLease,
  type SessionProductLease,
} from "@comma/session-contract";
import type { StatusMenuRow } from "@comma/chat-contract";
import type { StatusMenu } from "./native-status-menu";
import type { StatusTrayUsageSnapshot } from "./status-tray-usage";
import { shortcutAccelerator } from "./open-comma-shortcut";

export interface StatusTrayIconLike {
  resize(options: { height: number; width: number }): StatusTrayIconLike;
  setTemplateImage(template: boolean): void;
}

export interface StatusTrayIconFactory<Icon extends StatusTrayIconLike> {
  createFromPath(path: string): Icon;
}

export interface StatusTrayTask {
  conversationId: string;
  groupId: string;
  title: string;
  workspaceId: string;
}

/** The menu-bar menu's changing rows; everything else in it is fixed. */
export interface StatusTrayContent {
  /** The accelerator of the global shortcut, while it is the one that opens Comma. */
  openCommaAccelerator?: string | undefined;
  /** The app's Settings chord, as the renderer publishes it for the app menu. */
  settingsAccelerator?: string | undefined;
  /** The In progress Tasks; without one, the menu has no Task section. */
  inProgressTasks: readonly StatusTrayTask[];
  /** Main's language, when the app language changed after the tray was created. */
  locale?: CommaLocale | undefined;
  /** Quick Chat runs: a left click on the item starts it, and the menu opens on a right click. */
  quickChat?: boolean | undefined;
  /** Comma's credits and the person's own plans, for a signed-in session. */
  usage?: StatusTrayUsageSnapshot | undefined;
}

export interface StatusTrayMenuItem {
  accelerator?: string;
  click?: () => void;
  /** At the right: an item's status (a capsule), a meter's figure. */
  detail?: string;
  enabled?: boolean;
  /** A meter's bar, filled to this share (0–1). */
  fraction?: number;
  id?: string;
  label?: string;
  registerAccelerator?: boolean;
  role?: "quit";
  /** A gesture no accelerator can name ("Double-tap ⌘"), shown where a shortcut is. */
  shortcutText?: string;
  tone?: "normal" | "critical";
  /** A meter is a usage row that cannot be chosen. */
  type?: "header" | "separator" | "meter";
}

/** A row as Electron's Menu takes it: no meter, the detail or gesture in the label. */
export type StatusTrayElectronItem = Omit<
  StatusTrayMenuItem,
  "detail" | "fraction" | "shortcutText" | "tone" | "type"
> & { type?: "header" | "separator" };

export interface StatusTrayMenuLike {
  on(event: "menu-will-close" | "menu-will-show", listener: () => void): unknown;
}

export interface StatusTrayLike {
  destroy(): void;
  on(
    event: "click" | "right-click",
    listener: (event?: { ctrlKey?: boolean }) => void
  ): unknown;
  popUpContextMenu(menu?: unknown): void;
  setContextMenu(menu: unknown): void;
  setToolTip(toolTip: string): void;
}

/** What draws the menu-bar menu: the menu-bar helper on macOS, Electron's Tray elsewhere. */
export interface StatusTrayHost {
  /** How a Task title, whitespace already collapsed, reads in this menu. */
  taskLabel(title: string): string;
  /**
   * Shows these rows; rows that land while the menu is open wait until it
   * closes. With `click`, a left click on the item runs it instead of opening
   * the menu, which opens on a right click. `open` runs as the menu opens.
   */
  setMenu(items: StatusTrayMenuItem[], click?: () => void, open?: () => void): void;
  destroy(): void;
}

export const statusTrayTaskLimit = 5;
// The macOS menu is this many points wide. It has no key-equivalent column,
// so a Task title runs to the right edge, where every shortcut ends.
export const statusMenuWidth = 260;
/** The id a left click on the helper's item arrives with, when it runs an action; no row has it. */
const statusItemClickId = "status-item";
/** The ids the helper reports as the menu opens and once it has closed. */
const statusMenuOpenId = "status-menu:open";
const statusMenuCloseId = "status-menu:close";
// More of a title than the menu can show: the helper cuts it at the edge.
const statusMenuTitleLength = 256;
// A menu Electron draws has one column for every title and one for every
// accelerator. A Task row cannot use the accelerator column, so each point of
// title widens the menu. Long titles end at this edge: about 26 Latin or 13 CJK
// characters of the 13 pt menu font.
const taskTitleWidth = 170;
// Main cannot measure the font such a menu uses, so approximate it: a CJK glyph
// or an emoji takes one em, and other glyphs average about half an em.
const approximateWideGlyphWidth = 13;
const approximateGlyphWidth = 6.6;
const wideCharacter =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}　-〿！-｠]|\p{Extended_Pictographic}/u;

export function createCommaStatusTrayIcon<Icon extends StatusTrayIconLike>({
  iconPath,
  nativeImage,
  platform,
}: {
  iconPath: string;
  nativeImage: StatusTrayIconFactory<Icon>;
  platform: NodeJS.Platform;
}) {
  const icon = nativeImage.createFromPath(iconPath);
  if (platform === "darwin") icon.setTemplateImage(true);
  return icon;
}

/** The Tasks in the In progress column of the Tasks page, newest first. */
export function inProgressStatusTrayTasks(
  items: readonly ProductInboxItem[]
): StatusTrayTask[] {
  return items
    .filter(
      (item) =>
        item.kind === "agent_task" && taskStatusBucket(item.status) === "in_progress"
    )
    .toSorted((left, right) => right.updatedAt - left.updatedAt)
    .slice(0, statusTrayTaskLimit)
    .map(({ conversationId, groupId, title, workspaceId }) => ({
      conversationId,
      groupId,
      title,
      workspaceId,
    }));
}

/** Shows the chord only while it is the one that actually opens Comma. */
export function statusTrayPreferenceContent(
  preferences: AppPreferences
): Pick<StatusTrayContent, "openCommaAccelerator"> {
  const settings = preferences.clientSettings ?? defaultCommaClientSettings;
  return {
    openCommaAccelerator:
      preferences.openCommaShortcutStatus === "registered"
        ? shortcutAccelerator(settings.openCommaShortcut)
        : undefined,
  };
}

/**
 * Keeps the menu's In progress Tasks current while the menu-bar item is shown
 * for a signed-in session, including while every Comma window is closed. It
 * holds one ProductInbox subscription, which shares the runtime's single Task
 * event stream and refresh slot with the windows: no timer or request of its own.
 */
export class StatusTrayInProgressTasks {
  readonly #onChanged: (tasks: readonly StatusTrayTask[]) => void;
  readonly #subscribe: (listener: (list: ProductInboxListResult) => void) => () => void;
  #session: SessionProductLease | undefined;
  #tasks: readonly StatusTrayTask[] = [];
  #unsubscribe: (() => void) | undefined;

  constructor({
    onChanged,
    subscribe,
  }: {
    onChanged(tasks: readonly StatusTrayTask[]): void;
    /** The client core's list (the workspace in focus) for the signed-in account. */
    subscribe(listener: (list: ProductInboxListResult) => void): () => void;
  }) {
    this.#onChanged = onChanged;
    this.#subscribe = subscribe;
  }

  get tasks() {
    return this.#tasks;
  }

  /** Follows `session`, or stops holding demand when it is undefined. */
  follow(session: SessionProductLease | undefined) {
    if (
      session === this.#session ||
      (session && this.#session && sameSessionProductLease(session, this.#session))
    ) {
      return;
    }
    this.#unsubscribe?.();
    this.#unsubscribe = undefined;
    this.#session = undefined;
    this.#publish([]);
    if (!session) return;
    this.#unsubscribe = this.#subscribe((list) => {
      this.#publish(inProgressStatusTrayTasks(list.items));
    });
    this.#session = session;
  }

  #publish(tasks: readonly StatusTrayTask[]) {
    if (JSON.stringify(tasks) === JSON.stringify(this.#tasks)) return;
    this.#tasks = tasks;
    this.#onChanged(tasks);
  }
}

export function statusTrayTaskRoute(task: StatusTrayTask) {
  return `/tasks/${[task.workspaceId, task.groupId, task.conversationId]
    .map(encodeURIComponent)
    .join("/")}`;
}

export function createCommaStatusTray({
  content,
  createHost,
  locale = baseLocale,
  onOpenMainApp,
  onOpenSettings,
  onOpenTask,
  onOpenTasks,
  onOpenUsageSettings,
  onMenuOpened,
  onQuickChat,
  onRefreshUsage,
  now = Date.now,
  productName,
}: {
  content: StatusTrayContent;
  /**
   * Shows the menu-bar item with this tooltip. A host that changes how it draws
   * the menu calls `reinstall` to receive the rows again.
   */
  createHost(toolTip: string, reinstall: () => void): StatusTrayHost;
  locale?: CommaLocale;
  onOpenMainApp(): void;
  onOpenSettings(): void;
  onOpenTask(task: StatusTrayTask): void;
  /** Opens the Tasks page, which lists every Task. */
  onOpenTasks(): void;
  /** Usage settings...: Settings › Usage & billing. */
  onOpenUsageSettings(): void;
  /** The menu opened: the usage it shows may be read again. */
  onMenuOpened(): void;
  /** A left click while `content.quickChat`: Quick Chat listens. */
  onQuickChat(): void;
  /** Refresh: the usage is read again now. */
  onRefreshUsage(): void;
  now?: () => number;
  productName: string;
}) {
  const host = createHost(
    messages.electron_tray_running({ productName }, { locale }),
    () => {
      installedKey = undefined;
      install();
    }
  );
  let current = content;
  let destroyed = false;
  let installedKey: string | undefined;

  function template(next: StatusTrayContent): StatusTrayMenuItem[] {
    const language = { locale: next.locale ?? locale };
    const tasks = next.inProgressTasks.map((task) => {
      const title = task.title.trim().replace(/\s+/g, " ");
      return {
        click: () => onOpenTask(task),
        id: `task:${task.groupId}/${task.conversationId}`,
        label: title
          ? host.taskLabel(title)
          : messages.electron_tray_untitled_task({}, language),
      };
    });
    return [
      {
        click: onOpenMainApp,
        id: "open-comma",
        label: messages.electron_tray_open({ productName }, language),
        ...shortcut(next.openCommaAccelerator),
      },
      // ⌘ held alone starts it, as does a left click on the item.
      ...(next.quickChat
        ? [
            {
              click: onQuickChat,
              id: "quick-chat",
              label: messages.electron_tray_quick_chat({}, language),
              shortcutText: messages.electron_tray_quick_chat_shortcut({}, language),
            },
          ]
        : []),
      ...(tasks.length > 0
        ? [
            { type: "separator" as const },
            // A section title on macOS; a disabled row elsewhere keeps it grey.
            {
              enabled: false,
              label: messages.tasks_in_progress({}, language),
              type: "header" as const,
            },
            ...tasks,
            {
              click: onOpenTasks,
              id: "more-tasks",
              label: messages.electron_tray_more_tasks({}, language),
            },
          ]
        : []),
      ...(next.usage
        ? [
            { type: "separator" as const },
            ...usageRows(next.usage, {
              locale: next.locale ?? locale,
              now: now(),
              onOpenUsageSettings,
              onRefreshUsage,
              productName,
            }),
          ]
        : []),
      { type: "separator" },
      {
        click: onOpenSettings,
        id: "settings",
        label: messages.electron_tray_settings({}, language),
        ...shortcut(next.settingsAccelerator),
      },
      { type: "separator" },
      {
        id: "quit",
        label: messages.electron_tray_quit({ productName }, language),
        role: "quit",
      },
    ];
  }

  // The rows as shown, times included: the same rows are not sent again.
  function install() {
    if (destroyed) return;
    const items = template(current);
    const key = JSON.stringify([items, current.quickChat === true]);
    if (key === installedKey) return;
    installedKey = key;
    host.setMenu(items, current.quickChat ? onQuickChat : undefined, opened);
  }

  // Times are said from now as the menu opens; its usage may be read again.
  function opened() {
    install();
    onMenuOpened();
  }

  install();
  return {
    destroy() {
      destroyed = true;
      host.destroy();
    },
    update(next: StatusTrayContent) {
      current = next;
      install();
    },
  };
}

/** A meter whose plan has less than this left (in percent) draws its bar red, as Settings does. */
const criticalPercentLeft = 10;

function header(label: string): StatusTrayMenuItem {
  return { enabled: false, label, type: "header" };
}

/** A meter row: its figure, and a bar when `used` (in percent) is known. */
function meter(
  id: string,
  label: string,
  detail: string,
  used?: number
): StatusTrayMenuItem {
  return {
    detail,
    enabled: false,
    id,
    label,
    type: "meter",
    ...(used === undefined
      ? {}
      : {
          fraction: Math.min(1, Math.max(0, used / 100)),
          tone: 100 - used < criticalPercentLeft ? "critical" : "normal",
        }),
  };
}

function percent(value: number) {
  return Math.round(Math.min(100, Math.max(0, value)));
}

/** The usage block: Comma's credits, each of the person's plans, Refresh and Usage settings. */
function usageRows(
  usage: StatusTrayUsageSnapshot,
  {
    locale,
    now,
    onOpenUsageSettings,
    onRefreshUsage,
    productName,
  }: {
    locale: CommaLocale;
    now: number;
    onOpenUsageSettings(): void;
    onRefreshUsage(): void;
    productName: string;
  }
): StatusTrayMenuItem[] {
  const language = { locale };
  const credits = (value: number) =>
    formatNumber(value, locale, { notation: "compact", maximumFractionDigits: 1 });
  // How much is used, with its bar, and when it resets. Past its reset the
  // figure is from before it: the row says it reset (or ended) instead, with
  // no figure or bar, until a read lands.
  const usedMeter = (
    id: string,
    label: string,
    used: number,
    resetAt: string | null | undefined,
    ends = false
  ) => {
    const until = resetAt ? Date.parse(resetAt) - now : Number.NaN;
    if (until <= 0)
      return meter(
        id,
        label,
        ends
          ? messages.electron_tray_usage_ended({}, language)
          : messages.electron_tray_usage_reset({}, language)
      );
    if (!Number.isFinite(until))
      return meter(
        id,
        label,
        messages.electron_tray_usage_used({ percent: used }, language),
        used
      );
    const duration = durationText(until, locale);
    return meter(
      id,
      label,
      ends
        ? messages.electron_tray_usage_used_ends({ duration, percent: used }, language)
        : messages.electron_tray_usage_used_resets(
            { duration, percent: used },
            language
          ),
      used
    );
  };

  const comma = usage.comma;
  const commaRows: StatusTrayMenuItem[] =
    comma.status !== "ready"
      ? [
          header(messages.electron_tray_usage_header({ productName }, language)),
          meter(
            "usage:comma",
            messages.electron_tray_usage_credits({}, language),
            comma.status === "loading"
              ? messages.electron_tray_usage_loading({}, language)
              : messages.electron_tray_usage_unavailable({}, language)
          ),
        ]
      : [
          header(
            comma.plan ?? messages.electron_tray_usage_header({ productName }, language)
          ),
          ...(comma.usage
            ? [
                usedMeter(
                  "usage:comma",
                  messages.electron_tray_usage_monthly_credits({}, language),
                  percent(comma.usage.usedPercent),
                  comma.usage.resetsAt,
                  comma.usage.ends
                ),
                ...(comma.usage.otherCredits > 0
                  ? [
                      meter(
                        "usage:extra",
                        messages.electron_tray_usage_extra_credits({}, language),
                        messages.electron_tray_usage_credits_left(
                          { credits: credits(comma.usage.otherCredits) },
                          language
                        )
                      ),
                    ]
                  : []),
              ]
            : [
                meter(
                  "usage:comma",
                  messages.electron_tray_usage_credits({}, language),
                  comma.unlimited
                    ? messages.electron_tray_usage_unlimited({}, language)
                    : comma.credits > 0
                      ? messages.electron_tray_usage_credits_left(
                          { credits: credits(comma.credits) },
                          language
                        )
                      : messages.electron_tray_usage_credits_none({}, language)
                ),
              ]),
        ];

  // Two plans with the same title are told apart by their account.
  const titles = usage.accounts.map((account) =>
    account.plan
      ? messages.electron_tray_usage_account(
          { plan: capitalized(account.plan, locale), provider: account.provider },
          language
        )
      : account.provider
  );
  // Each plan is a section of its own, under a line.
  const accountRows = usage.accounts.flatMap((account, index): StatusTrayMenuItem[] => [
    { type: "separator" },
    header(
      titles.indexOf(titles[index]!) === titles.lastIndexOf(titles[index]!)
        ? titles[index]!
        : messages.electron_tray_usage_account(
            { plan: account.name, provider: account.provider },
            language
          )
    ),
    ...account.meters.map((window) =>
      usedMeter(
        `usage:${account.id}:${window.window}`,
        window.window === "5h"
          ? messages.electron_tray_usage_5h({}, language)
          : messages.electron_tray_usage_week({}, language),
        percent(100 - window.percent),
        window.resetAt
      )
    ),
  ]);

  const refresh = usage.refresh;
  const refreshDetail =
    refresh.state === "updating"
      ? messages.electron_tray_usage_updating({}, language)
      : refresh.state === "failed"
        ? messages.electron_tray_usage_update_failed({}, language)
        : refresh.updatedAt === null
          ? undefined
          : now - refresh.updatedAt < 60_000
            ? messages.electron_tray_usage_updated_now({}, language)
            : messages.electron_tray_usage_updated(
                { time: formatRelativeTime(refresh.updatedAt, locale, now) },
                language
              );
  return [
    ...commaRows,
    ...accountRows,
    {
      click: onRefreshUsage,
      id: "usage:refresh",
      label: messages.electron_tray_usage_refresh({}, language),
      ...(refreshDetail ? { detail: refreshDetail } : {}),
    },
    {
      click: onOpenUsageSettings,
      id: "usage:settings",
      label: messages.electron_tray_usage_settings({}, language),
    },
  ];
}

/** How long until a reset, in its largest whole unit ("3h", "4d"; at least a minute). */
function durationText(ms: number, locale: CommaLocale) {
  const minutes = Math.max(1, Math.round(ms / 60_000));
  const [value, unit] =
    minutes >= 24 * 60
      ? [Math.round(minutes / (24 * 60)), "day"]
      : minutes >= 60
        ? [Math.round(minutes / 60), "hour"]
        : [minutes, "minute"];
  return formatNumber(value, locale, { style: "unit", unit, unitDisplay: "narrow" });
}

/** A provider's plan name as Settings shows it ("max" → "Max"). */
function capitalized(plan: string, locale: CommaLocale) {
  return plan.charAt(0).toLocaleUpperCase(locale) + plan.slice(1);
}

/** The helper process that draws the macOS menu-bar item. */
export interface StatusMenuHelper {
  hideStatusMenu(): void;
  /** `menu.clickId`, when set, arrives at `onSelect` as a left click on the item. */
  showStatusMenu(
    menu: StatusMenu,
    onSelect: (id: string) => void,
    onLost: () => void
  ): void;
}

/**
 * `primary` until it loses the menu, then `fallback` for good. The menu-bar
 * item must outlive a helper that keeps failing, for example one whose saved
 * shortcut another app has taken: its Settings and Quit rows are how to recover.
 */
export function fallbackStatusTrayHost({
  createFallback,
  createPrimary,
  reinstall,
}: {
  createFallback(): StatusTrayHost;
  createPrimary(onLost: () => void): StatusTrayHost;
  /** Sends the rows again, labeled for the fallback. */
  reinstall(): void;
}): StatusTrayHost {
  let destroyed = false;
  let current: StatusTrayHost;
  const primary = createPrimary(() => {
    if (destroyed || current !== primary) return;
    current = createFallback();
    reinstall();
  });
  current = primary;
  return {
    taskLabel: (title) => current.taskLabel(title),
    setMenu: (items, click, open) => current.setMenu(items, click, open),
    destroy() {
      destroyed = true;
      current.destroy();
    },
  };
}

/** The macOS menu-bar item, drawn by the menu-bar helper (`NativeStatusMenuService`). */
export function helperStatusTrayHost({
  helper,
  iconPath,
  onLost,
  onQuit,
  toolTip,
}: {
  helper: StatusMenuHelper;
  iconPath: string;
  /** The helper is gone and with it the menu-bar item. */
  onLost(): void;
  onQuit(): void;
  toolTip: string;
}): StatusTrayHost {
  // The open menu can still show rows sent before the latest update, which
  // wait for it to close. A row chosen from it runs the click it had: while
  // it is open, every row sent since it opened keeps its click, and so do the
  // rows before the latest, which it can open with as the latest is on its
  // way. The helper reports the close after the chosen row.
  let clicks = new Map<string, () => void>();
  let previousClicks = clicks;
  let openClicks: Map<string, () => void> | undefined;
  const select = (id: string) => {
    if (id === statusMenuCloseId) {
      openClicks = undefined;
      return;
    }
    if (id === statusMenuOpenId) openClicks = new Map(previousClicks);
    (clicks.get(id) ?? openClicks?.get(id) ?? previousClicks.get(id))?.();
  };
  return {
    // The helper ends a long title at the menu's right edge.
    taskLabel: (title) => Array.from(title).slice(0, statusMenuTitleLength).join(""),
    setMenu(items, itemClick, open) {
      if (openClicks) for (const [id, click] of clicks) openClicks.set(id, click);
      previousClicks = clicks;
      clicks = new Map();
      if (itemClick) clicks.set(statusItemClickId, itemClick);
      if (open) clicks.set(statusMenuOpenId, open);
      const rows = items.map((item, index): StatusMenuRow => {
        if (item.type === "separator") return { kind: "separator" };
        const title = item.label ?? "";
        if (item.type === "header") return { kind: "header", title };
        const detail = item.detail ? { detail: item.detail.slice(0, 128) } : {};
        if (item.type === "meter") {
          return {
            ...detail,
            ...(item.fraction === undefined
              ? {}
              : { fraction: Math.min(1, Math.max(0, item.fraction)) }),
            ...(item.id ? { id: item.id } : {}),
            kind: "meter",
            title,
            ...(item.tone ? { tone: item.tone } : {}),
          };
        }
        const id = item.id ?? `row:${index}`;
        const quit = item.role === "quit";
        const click = quit ? onQuit : item.click;
        if (click) clicks.set(id, click);
        const accelerator = quit ? "CommandOrControl+Q" : item.accelerator;
        const shortcutText = accelerator
          ? menuShortcutText(accelerator)
          : item.shortcutText;
        return {
          ...detail,
          id,
          kind: "item",
          title,
          ...(shortcutText ? { shortcut: shortcutText } : {}),
        };
      });
      helper.showStatusMenu(
        {
          ...(itemClick ? { clickId: statusItemClickId } : {}),
          ...(open ? { closeId: statusMenuCloseId, openId: statusMenuOpenId } : {}),
          iconPath,
          rows,
          toolTip,
          width: statusMenuWidth,
        },
        select,
        onLost
      );
    },
    destroy: () => helper.hideStatusMenu(),
  };
}

/** Electron's Tray and Menu: Windows and Linux, and a Mac without the menu-bar helper. */
export function electronStatusTrayHost({
  buildMenu,
  createTray,
  platform = process.platform,
  schedule = (task) => setTimeout(task, 0),
  toolTip,
}: {
  buildMenu(template: StatusTrayElectronItem[]): StatusTrayMenuLike;
  createTray(): StatusTrayLike;
  platform?: NodeJS.Platform;
  schedule?: (task: () => void) => void;
  toolTip: string;
}): StatusTrayHost {
  const tray = createTray();
  tray.setToolTip(toolTip);
  let destroyed = false;
  let menuOpen = false;
  let pending:
    | {
        items: StatusTrayMenuItem[];
        click: (() => void) | undefined;
        open: (() => void) | undefined;
      }
    | undefined;
  let open: (() => void) | undefined;
  let menu: StatusTrayMenuLike | undefined;
  let click: (() => void) | undefined;
  // macOS and Windows report the item's clicks, and the menu pops up from
  // here with its rows built as it opens (times are said from then). Linux
  // shows the tray's context menu itself, unless a click action takes the
  // left click; its rows were built when they last changed.
  const popsUp = platform !== "linux";
  const popUp = () => {
    open?.();
    if (menu) tray.popUpContextMenu(menu);
  };
  // Control-click is a right click on macOS, where a left click opens the menu.
  tray.on("click", (event) => {
    if (click && !event?.ctrlKey) click();
    else if (click || platform === "darwin") popUp();
  });
  tray.on("right-click", () => {
    if (click || popsUp) popUp();
  });

  function install() {
    // Swapping the menu while it is open drops the rows under the pointer; a
    // change that lands then is installed once the menu closes.
    if (destroyed || menuOpen || !pending) return;
    const next = buildMenu(pending.items.map(electronItem));
    click = pending.click;
    open = pending.open;
    pending = undefined;
    next.on("menu-will-show", () => {
      menuOpen = true;
      // A menu popped up from here was told already.
      if (!popsUp && !click) open?.();
    });
    next.on("menu-will-close", () => {
      menuOpen = false;
      // AppKit delivers the chosen row's click after this event. Replacing
      // the menu inside it would release that row before it fires.
      schedule(install);
    });
    menu = next;
    tray.setContextMenu(popsUp || click ? null : next);
  }

  return {
    // Electron reads a single "&" as a Windows mnemonic marker and drops it.
    taskLabel: (title) => fittedTaskTitle(title).replaceAll("&", "&&"),
    setMenu(items, onClick, onOpen) {
      pending = { items, click: onClick, open: onOpen };
      install();
    },
    destroy() {
      destroyed = true;
      tray.destroy();
    },
  };
}

/**
 * A row as Electron's Menu takes it. A meter is a grey row without a bar, and
 * a figure follows its title (a sublabel needs macOS 14.4).
 */
function electronItem(item: StatusTrayMenuItem): StatusTrayElectronItem {
  const {
    detail,
    fraction: _fraction,
    shortcutText,
    tone: _tone,
    type,
    ...rest
  } = item;
  const shown = type === "meter" ? { ...rest, enabled: false } : rest;
  const kind = type === "header" || type === "separator" ? { type } : {};
  const trailing = detail ?? shortcutText;
  return trailing
    ? { ...shown, ...kind, label: `${rest.label ?? ""} · ${trailing}` }
    : { ...shown, ...kind };
}

function shortcut(accelerator: string | undefined) {
  // Another owner registers the chord (a global shortcut or the app menu);
  // the row only shows it.
  return accelerator ? { accelerator, registerAccelerator: false } : {};
}

// What macOS draws for a key equivalent: the modifiers in ⌃⌥⇧⌘ order, then the key.
const shortcutModifiers: ReadonlyArray<readonly [string, readonly string[]]> = [
  ["⌃", ["control", "ctrl"]],
  ["⌥", ["alt", "option", "altgr"]],
  ["⇧", ["shift"]],
  ["⌘", ["super", "command", "cmd", "meta", "commandorcontrol", "cmdorctrl"]],
];
const shortcutKeys: Readonly<Record<string, string>> = {
  arrowdown: "↓",
  arrowleft: "←",
  arrowright: "→",
  arrowup: "↑",
  backquote: "`",
  backslash: "\\",
  backspace: "⌫",
  delete: "⌦",
  down: "↓",
  end: "↘",
  enter: "↩",
  equal: "=",
  esc: "⎋",
  escape: "⎋",
  home: "↖",
  left: "←",
  minus: "-",
  pagedown: "⇟",
  pageup: "⇞",
  period: ".",
  plus: "+",
  quote: "'",
  return: "↩",
  right: "→",
  semicolon: ";",
  slash: "/",
  space: "Space",
  tab: "⇥",
  up: "↑",
};

/** An Electron accelerator ("Control+Alt+Space") as the menu shows it ("⌃⌥ Space"). */
export function menuShortcutText(accelerator: string) {
  const parts = accelerator.split("+");
  const key = parts.pop() ?? "";
  const modifiers = new Set(parts.map((part) => part.toLowerCase()));
  const glyphs = shortcutModifiers
    .filter(([, names]) => names.some((name) => modifiers.has(name)))
    .map(([glyph]) => glyph)
    .join("");
  const keyText = shortcutKeys[key.toLowerCase()] ?? key.toUpperCase();
  return glyphs ? `${glyphs} ${keyText}` : keyText;
}

const graphemes = (text: string) =>
  Array.from(
    new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(text),
    ({ segment }) => segment
  );

function approximateMenuTextWidth(text: string) {
  return graphemes(text).reduce(
    (width, glyph) =>
      width +
      (wideCharacter.test(glyph) ? approximateWideGlyphWidth : approximateGlyphWidth),
    0
  );
}

/** The whole title, or its longest prefix whose "…" form fits the column. */
function fittedTaskTitle(title: string) {
  if (approximateMenuTextWidth(title) <= taskTitleWidth) return title;
  const glyphs = graphemes(title);
  const truncated = (count: number) => `${glyphs.slice(0, count).join("").trimEnd()}…`;
  // Binary search: `fits` always fits, `tooLong` never does.
  let fits = 0;
  let tooLong = glyphs.length;
  while (tooLong - fits > 1) {
    const middle = Math.floor((fits + tooLong) / 2);
    if (approximateMenuTextWidth(truncated(middle)) <= taskTitleWidth) fits = middle;
    else tooLong = middle;
  }
  return truncated(fits);
}

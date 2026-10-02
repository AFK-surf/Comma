import { baseLocale, messages, taskStatusBucket, type CommaLocale } from "@comma/i18n";
import {
  defaultCommaClientSettings,
  type AppPreferences,
  type CommaOperatingSystem,
  type ProductInboxItem,
} from "@comma/native-bridge";
import {
  sameSessionProductLease,
  type SessionProductLease,
} from "@comma/session-contract";
import type { StatusMenuRow } from "@comma/chat-contract";
import type { ProductInboxStateEnvelope } from "./modules/product-inbox";
import type { StatusMenu } from "./native-side-chat";
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
  /** Accelerators of the global shortcuts that currently open each surface. */
  openCommaAccelerator?: string | undefined;
  sideChatAccelerator?: string | undefined;
  /** False hides the Open Side Chat row, as Side Chat is turned off in General. */
  sideChatEnabled?: boolean | undefined;
  /** The app's Settings chord, as the renderer publishes it for the app menu. */
  settingsAccelerator?: string | undefined;
  /** The In progress Tasks; without one, the menu has no Task section. */
  inProgressTasks: readonly StatusTrayTask[];
  /** Main's language, when the app language changed after the tray was created. */
  locale?: CommaLocale | undefined;
}

export interface StatusTrayMenuItem {
  accelerator?: string;
  click?: () => void;
  enabled?: boolean;
  id?: string;
  label?: string;
  registerAccelerator?: boolean;
  role?: "quit";
  type?: "header" | "separator";
}

export interface StatusTrayMenuLike {
  on(event: "menu-will-close" | "menu-will-show", listener: () => void): unknown;
}

export interface StatusTrayLike {
  destroy(): void;
  setContextMenu(menu: unknown): void;
  setToolTip(toolTip: string): void;
}

/** What draws the menu-bar menu: the Side Chat helper on macOS, Electron's Tray elsewhere. */
export interface StatusTrayHost {
  /** How a Task title, whitespace already collapsed, reads in this menu. */
  taskLabel(title: string): string;
  /** Shows these rows; rows that land while the menu is open wait until it closes. */
  setMenu(items: StatusTrayMenuItem[]): void;
  destroy(): void;
}

export const statusTrayTaskLimit = 5;
// The macOS menu is this many points wide. It has no key-equivalent column,
// so a Task title runs to the right edge, where every shortcut ends.
export const statusMenuWidth = 260;
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

/**
 * Shows a chord only while it is the one that actually opens the surface, and
 * the Side Chat row only while Side Chat is on.
 */
export function statusTrayPreferenceContent(
  preferences: AppPreferences,
  os: CommaOperatingSystem
): Pick<
  StatusTrayContent,
  "openCommaAccelerator" | "sideChatAccelerator" | "sideChatEnabled"
> {
  const settings = preferences.clientSettings ?? defaultCommaClientSettings;
  return {
    openCommaAccelerator:
      preferences.openCommaShortcutStatus === "registered"
        ? shortcutAccelerator(settings.openCommaShortcut)
        : undefined,
    // Only the macOS Side Chat helper registers this chord.
    sideChatAccelerator:
      os === "macos" ? shortcutAccelerator(settings.sideChatShortcut) : undefined,
    sideChatEnabled: preferences.sideChatEnabled,
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
  readonly #subscribe: (
    session: SessionProductLease,
    listener: (envelope: ProductInboxStateEnvelope) => void
  ) => () => void;
  #session: SessionProductLease | undefined;
  #tasks: readonly StatusTrayTask[] = [];
  #unsubscribe: (() => void) | undefined;

  constructor({
    onChanged,
    subscribe,
  }: {
    onChanged(tasks: readonly StatusTrayTask[]): void;
    subscribe(
      session: SessionProductLease,
      listener: (envelope: ProductInboxStateEnvelope) => void
    ): () => void;
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
    this.#unsubscribe = this.#subscribe(session, ({ snapshot }) => {
      this.#publish(inProgressStatusTrayTasks(snapshot.items));
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
  onOpenSideChat,
  onOpenTask,
  onOpenTasks,
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
  onOpenSideChat(): void;
  onOpenTask(task: StatusTrayTask): void;
  /** Opens the Tasks page, which lists every Task. */
  onOpenTasks(): void;
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
      ...(next.sideChatEnabled === false
        ? []
        : [
            {
              click: onOpenSideChat,
              id: "open-side-chat",
              label: messages.electron_tray_open_side_chat({}, language),
              ...shortcut(next.sideChatAccelerator),
            },
          ]),
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

  function install() {
    const key = JSON.stringify(current);
    if (destroyed || key === installedKey) return;
    installedKey = key;
    host.setMenu(template(current));
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

/** The helper process that draws the macOS menu-bar item. */
export interface StatusMenuHelper {
  hideStatusMenu(): void;
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
    setMenu: (items) => current.setMenu(items),
    destroy() {
      destroyed = true;
      current.destroy();
    },
  };
}

/** The macOS menu-bar item, drawn by the Side Chat helper. */
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
  // The menu on screen can still show the rows before the latest update, which
  // wait for it to close. A row chosen from it runs that generation's click.
  let clicks = new Map<string, () => void>();
  let previousClicks = clicks;
  const select = (id: string) => (clicks.get(id) ?? previousClicks.get(id))?.();
  return {
    // The helper ends a long title at the menu's right edge.
    taskLabel: (title) => Array.from(title).slice(0, statusMenuTitleLength).join(""),
    setMenu(items) {
      previousClicks = clicks;
      clicks = new Map();
      const rows = items.map((item, index): StatusMenuRow => {
        if (item.type === "separator") return { kind: "separator" };
        const title = item.label ?? "";
        if (item.type === "header") return { kind: "header", title };
        const id = item.id ?? `row:${index}`;
        const quit = item.role === "quit";
        const click = quit ? onQuit : item.click;
        if (click) clicks.set(id, click);
        const accelerator = quit ? "CommandOrControl+Q" : item.accelerator;
        return {
          id,
          kind: "item",
          title,
          ...(accelerator ? { shortcut: menuShortcutText(accelerator) } : {}),
        };
      });
      helper.showStatusMenu(
        { iconPath, rows, toolTip, width: statusMenuWidth },
        select,
        onLost
      );
    },
    destroy: () => helper.hideStatusMenu(),
  };
}

/** Electron's Tray and Menu: Windows and Linux, and a Mac without the Side Chat helper. */
export function electronStatusTrayHost({
  buildMenu,
  createTray,
  schedule = (task) => setTimeout(task, 0),
  toolTip,
}: {
  buildMenu(template: StatusTrayMenuItem[]): StatusTrayMenuLike;
  createTray(): StatusTrayLike;
  schedule?: (task: () => void) => void;
  toolTip: string;
}): StatusTrayHost {
  const tray = createTray();
  tray.setToolTip(toolTip);
  let destroyed = false;
  let menuOpen = false;
  let pending: StatusTrayMenuItem[] | undefined;

  function install() {
    // Swapping the menu while it is open drops the rows under the pointer; a
    // change that lands then is installed once the menu closes.
    if (destroyed || menuOpen || !pending) return;
    const menu = buildMenu(pending);
    pending = undefined;
    menu.on("menu-will-show", () => {
      menuOpen = true;
    });
    menu.on("menu-will-close", () => {
      menuOpen = false;
      // AppKit delivers the chosen row's click after this event. Replacing
      // the menu inside it would release that row before it fires.
      schedule(install);
    });
    tray.setContextMenu(menu);
  }

  return {
    // Electron reads a single "&" as a Windows mnemonic marker and drops it.
    taskLabel: (title) => fittedTaskTitle(title).replaceAll("&", "&&"),
    setMenu(items) {
      pending = items;
      install();
    },
    destroy() {
      destroyed = true;
      tray.destroy();
    },
  };
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

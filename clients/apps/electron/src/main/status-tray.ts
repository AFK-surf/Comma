import { baseLocale, messages, type CommaLocale } from "@comma/i18n";
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
import type { ProductInboxStateEnvelope } from "./modules/product-inbox";
import { shortcutAccelerator } from "./open-comma-shortcut";

export interface StatusTrayIconLike {
  resize(options: { height: number; width: number }): StatusTrayIconLike;
  setTemplateImage(template: boolean): void;
}

export interface StatusTrayIconFactory {
  createFromPath(path: string): StatusTrayIconLike;
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
  /** The app's Settings chord, as the renderer publishes it for the app menu. */
  settingsAccelerator?: string | undefined;
  recentTasks: readonly StatusTrayTask[];
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

export const statusTrayRecentTaskLimit = 5;
// AppKit lays a menu out in two columns: one for every title and one for every
// key equivalent. A Task row cannot use the key column, so each point of title
// widens the menu. Long titles end at this edge, in points of the menu font:
// about 26 Latin or 13 CJK characters.
const taskTitleWidth = 170;
// Where Main cannot measure the menu font (other platforms, a font addon built
// before it could), approximate the 13 pt menu font: a CJK glyph or an emoji
// takes one em, and other glyphs average about half an em.
const approximateWideGlyphWidth = 13;
const approximateGlyphWidth = 6.6;
const wideCharacter =
  /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}　-〿！-｠]|\p{Extended_Pictographic}/u;

export function createCommaStatusTrayIcon({
  iconPath,
  nativeImage,
  platform,
}: {
  iconPath: string;
  nativeImage: StatusTrayIconFactory;
  platform: NodeJS.Platform;
}) {
  const icon = nativeImage.createFromPath(iconPath);
  if (platform === "darwin") icon.setTemplateImage(true);
  return icon;
}

/** The same "recent Tasks" the ⌘K palette lists, newest first. */
export function recentStatusTrayTasks(
  items: readonly ProductInboxItem[]
): StatusTrayTask[] {
  return items
    .filter((item) => item.kind === "agent_task" && item.status !== "archived")
    .toSorted((left, right) => right.updatedAt - left.updatedAt)
    .slice(0, statusTrayRecentTaskLimit)
    .map(({ conversationId, groupId, title, workspaceId }) => ({
      conversationId,
      groupId,
      title,
      workspaceId,
    }));
}

/** Shows a chord only while it is the one that actually opens the surface. */
export function statusTrayAccelerators(
  preferences: AppPreferences,
  os: CommaOperatingSystem
): Pick<StatusTrayContent, "openCommaAccelerator" | "sideChatAccelerator"> {
  const settings = preferences.clientSettings ?? defaultCommaClientSettings;
  return {
    openCommaAccelerator:
      preferences.openCommaShortcutStatus === "registered"
        ? shortcutAccelerator(settings.openCommaShortcut)
        : undefined,
    // Only the macOS Side Chat helper registers this chord.
    sideChatAccelerator:
      os === "macos" ? shortcutAccelerator(settings.sideChatShortcut) : undefined,
  };
}

/**
 * Keeps the menu's recent Tasks current while the menu-bar item is shown for
 * a signed-in session, including while every Comma window is closed. It holds
 * one ProductInbox subscription, which shares the runtime's single Task event
 * stream and refresh slot with the windows: no timer or request of its own.
 */
export class StatusTrayRecentTasks {
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
      this.#publish(recentStatusTrayTasks(snapshot.items));
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
  buildMenu,
  content,
  createTray,
  icon,
  locale = baseLocale,
  onOpenMainApp,
  onOpenSettings,
  onOpenSideChat,
  measureMenuText,
  onOpenTask,
  productName,
  schedule = (task) => setTimeout(task, 0),
}: {
  buildMenu(template: StatusTrayMenuItem[]): StatusTrayMenuLike;
  content: StatusTrayContent;
  createTray(icon: unknown): StatusTrayLike;
  icon: unknown;
  locale?: CommaLocale;
  /** Points a string takes in the menu font, or null where Main cannot measure it. */
  measureMenuText?: (text: string) => number | null;
  onOpenMainApp(): void;
  onOpenSettings(): void;
  onOpenSideChat(): void;
  onOpenTask(task: StatusTrayTask): void;
  productName: string;
  schedule?: (task: () => void) => void;
}) {
  const tray = createTray(icon);
  tray.setToolTip(messages.electron_tray_running({ productName }, { locale }));
  let current = content;
  let destroyed = false;
  let installedKey: string | undefined;
  let menuOpen = false;
  const measure = (text: string) =>
    measureMenuText?.(text) ?? approximateMenuTextWidth(text);

  function template(next: StatusTrayContent): StatusTrayMenuItem[] {
    const tasks = next.recentTasks.map((task) => ({
      click: () => onOpenTask(task),
      id: `task:${task.groupId}/${task.conversationId}`,
      label:
        taskMenuLabel(task.title, measure) ||
        messages.electron_tray_untitled_task({}, { locale }),
    }));
    return [
      {
        click: onOpenMainApp,
        label: messages.electron_tray_open({ productName }, { locale }),
        ...shortcut(next.openCommaAccelerator),
      },
      {
        click: onOpenSideChat,
        label: messages.electron_tray_open_side_chat({}, { locale }),
        ...shortcut(next.sideChatAccelerator),
      },
      ...(tasks.length > 0
        ? [
            { type: "separator" as const },
            // A section title on macOS; a disabled row elsewhere keeps it grey.
            {
              enabled: false,
              label: messages.electron_tray_tasks({}, { locale }),
              type: "header" as const,
            },
            ...tasks,
          ]
        : []),
      { type: "separator" },
      {
        click: onOpenSettings,
        label: messages.electron_tray_settings({}, { locale }),
        ...shortcut(next.settingsAccelerator),
      },
      { type: "separator" },
      {
        label: messages.electron_tray_quit({ productName }, { locale }),
        role: "quit",
      },
    ];
  }

  function install() {
    const key = JSON.stringify(current);
    // Swapping the menu while it is open drops the rows under the pointer; a
    // change that lands then is installed once the menu closes.
    if (destroyed || menuOpen || key === installedKey) return;
    installedKey = key;
    const menu = buildMenu(template(current));
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

  install();
  return {
    destroy() {
      destroyed = true;
      tray.destroy();
    },
    update(next: StatusTrayContent) {
      current = next;
      install();
    },
  };
}

function shortcut(accelerator: string | undefined) {
  // Another owner registers the chord (a global shortcut or the app menu);
  // the row only shows it.
  return accelerator ? { accelerator, registerAccelerator: false } : {};
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
function taskMenuLabel(title: string, measure: (text: string) => number) {
  const text = title.trim().replace(/\s+/g, " ");
  let label = text;
  if (measure(text) > taskTitleWidth) {
    const glyphs = graphemes(text);
    const truncated = (count: number) =>
      `${glyphs.slice(0, count).join("").trimEnd()}…`;
    // Binary search: `fits` always fits, `tooLong` never does.
    let fits = 0;
    let tooLong = glyphs.length;
    while (tooLong - fits > 1) {
      const middle = Math.floor((fits + tooLong) / 2);
      if (measure(truncated(middle)) <= taskTitleWidth) fits = middle;
      else tooLong = middle;
    }
    label = truncated(fits);
  }
  // Electron reads a single "&" as a Windows mnemonic marker and drops it.
  return label.replaceAll("&", "&&");
}

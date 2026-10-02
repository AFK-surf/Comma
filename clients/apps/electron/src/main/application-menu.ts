import { applicationMenuIcons } from "./generated/application-menu-icons";
import { app, Menu, nativeImage, type MenuItemConstructorOptions } from "electron";
import type {
  ApplicationMenuCommand,
  ApplicationMenuItems,
} from "@comma/native-bridge";
import { applicationMenuProvider } from "./application-menu-provider";

type Options = {
  isMainFocused: () => boolean;
  dispatch: (id: ApplicationMenuCommand) => void;
  openMain: () => unknown;
  openSideChat: () => unknown;
  openSideChatBackground?: () => unknown;
  /** False hides Open Side Chat, as Side Chat is turned off in General. */
  sideChatEnabled: () => boolean;
};
const accelerators = (entries: ApplicationMenuItems) =>
  JSON.stringify(
    entries
      .filter((item) => item.accelerator)
      .map((item) => [item.id, item.accelerator])
      .toSorted(([left], [right]) => left!.localeCompare(right!))
  );

export function installApplicationMenu(options: Options) {
  const images = new Map(
    Object.entries(applicationMenuIcons).map(([id, data]) => {
      const image = nativeImage.createFromBuffer(Buffer.from(data, "base64"), {
        scaleFactor: 2,
      });
      image.setTemplateImage(true);
      return [id, image];
    })
  );
  let items: ApplicationMenuItems = [];
  let locale = "en";
  const translations: Record<string, string> = {
    File: "文件",
    View: "显示",
    Window: "窗口",
    "Settings…": "设置…",
    "Start Recording": "开始录音",
    "Pause Recording": "暂停录音",
    "Resume Recording": "继续录音",
    "Stop and Save Recording": "停止并保存录音",
    "Recording Settings…": "录音设置…",
    "Upload Files…": "上传文件…",
    "Upload Folder…": "上传文件夹…",
    "Add Local Folder to Drive…": "添加本地文件夹到 Drive…",
    "Download Selected Files": "下载选中文件",
    "New Browser Tab": "新建浏览器标签页",
    "Close Tab": "关闭标签页",
    Home: "首页",
    Inbox: "收件箱",
    Tasks: "任务",
    Plugins: "插件",
    "Search Tasks…": "搜索任务…",
    Back: "后退",
    Forward: "前进",
    "Show Left Sidebar": "显示左侧栏",
    "Show Right Sidebar": "显示右侧栏",
    "Show Comma": "显示 Comma",
    "Open Side Chat": "打开 Side Chat",
    "Side Chat Background…": "Side Chat 背景调试…",
    "Keyboard Shortcuts…": "快捷键…",
    "Check for Updates…": "检查更新…",
  };
  const t = (label: string) =>
    locale === "zh-CN" ? (translations[label] ?? label) : label;
  let menu: Menu | undefined;
  const labels = new Map<ApplicationMenuCommand, string>();

  function update() {
    if (!menu) return;
    const focused = options.isMainFocused();
    for (const [id, label] of labels) {
      const item = menu.getMenuItemById(id);
      if (!item) continue;
      const state = items.find((candidate) => candidate.id === id);
      item.enabled = (state?.enabled ?? false) && focused;
      item.label = state?.shortcutLabel
        ? `${t(label)}    ${state.shortcutLabel}`
        : t(label);
      if (item.type === "checkbox") item.checked = state?.checked ?? false;
      if (id === "record-resume") item.visible = state?.enabled ?? false;
      if (id === "record-pause") {
        item.visible = !items.some(
          (candidate) => candidate.id === "record-resume" && candidate.enabled
        );
      }
    }
    const sideChatItem = menu.getMenuItemById("open-side-chat");
    if (sideChatItem) sideChatItem.visible = options.sideChatEnabled();
  }

  function build() {
    const command = (
      id: ApplicationMenuCommand,
      label: string
    ): MenuItemConstructorOptions => {
      labels.set(id, label);
      const state = items.find((item) => item.id === id);
      return {
        ...(images.has(id) ? { icon: images.get(id)! } : {}),
        id,
        label: state?.shortcutLabel
          ? `${t(label)}    ${state.shortcutLabel}`
          : t(label),
        enabled: (state?.enabled ?? false) && options.isMainFocused(),
        ...(id === "record-resume" ? { visible: state?.enabled ?? false } : {}),
        ...(id === "record-pause"
          ? {
              visible: !items.some(
                (item) => item.id === "record-resume" && item.enabled
              ),
            }
          : {}),
        ...(id === "toggle-left-sidebar" || id === "toggle-right-sidebar"
          ? { type: "checkbox", checked: state?.checked ?? false }
          : {}),
        ...(state?.accelerator
          ? { accelerator: state.accelerator, acceleratorWorksWhenHidden: false }
          : {}),
        click: () => options.dispatch(id),
      };
    };
    const separator: MenuItemConstructorOptions = { type: "separator" };
    const template: MenuItemConstructorOptions[] = [
      {
        label: app.name,
        submenu: [
          { role: "about" },
          command("check-updates", "Check for Updates…"),
          separator,
          command("go-settings", "Settings…"),
          separator,
          { role: "services" },
          separator,
          { role: "hide" },
          { role: "hideOthers" },
          { role: "unhide" },
          separator,
          { role: "quit" },
        ],
      },
      {
        label: t("File"),
        submenu: [
          command("record-start", "Start Recording"),
          command("record-pause", "Pause Recording"),
          command("record-resume", "Resume Recording"),
          command("record-stop", "Stop and Save Recording"),
          command("go-recording-settings", "Recording Settings…"),
          separator,
          command("drive-upload", "Upload Files…"),
          command("drive-upload-folder", "Upload Folder…"),
          command("drive-add-folder", "Add Local Folder to Drive…"),
          command("drive-download", "Download Selected Files"),
          separator,
          command("browser-new-tab", "New Browser Tab"),
          command("browser-close-tab", "Close Tab"),
          separator,
          { role: "close" },
        ],
      },
      { role: "editMenu" },
      {
        label: t("View"),
        submenu: [
          command("go-comma-assistant", "Home"),
          command("go-inbox", "Inbox"),
          command("go-drive", "Drive"),
          command("go-tasks", "Tasks"),
          command("go-plugins", "Plugins"),
          command("go-routines", "Routines"),
          command("go-search", "Search Tasks…"),
          separator,
          command("history-back", "Back"),
          command("history-forward", "Forward"),
          separator,
          command("toggle-left-sidebar", "Show Left Sidebar"),
          command("toggle-right-sidebar", "Show Right Sidebar"),
          separator,
          { id: "toggle-devtools", role: "toggleDevTools" },
          ...(options.openSideChatBackground
            ? [
                {
                  id: "side-chat-background-debug",
                  label: t("Side Chat Background…"),
                  click: () => {
                    void options.openSideChatBackground?.();
                  },
                },
              ]
            : []),
          separator,
          { role: "zoomIn" },
          { role: "zoomOut" },
          { role: "resetZoom" },
          separator,
          { role: "togglefullscreen" },
        ],
      },
      {
        role: "windowMenu",
        label: t("Window"),
        submenu: [
          {
            label: t("Show Comma"),
            click: () => {
              void options.openMain();
            },
          },
          {
            id: "open-side-chat",
            label: t("Open Side Chat"),
            visible: options.sideChatEnabled(),
            click: () => {
              void options.openSideChat();
            },
          },
          separator,
          { role: "minimize" },
          { role: "zoom" },
          separator,
          { role: "front" },
        ],
      },
      { role: "help", submenu: [command("go-shortcuts", "Keyboard Shortcuts…")] },
    ];
    menu = Menu.buildFromTemplate(template);
    Menu.setApplicationMenu(menu);
  }
  applicationMenuProvider.subscribe((next) => {
    const structureChanged =
      locale !== next.locale || accelerators(items) !== accelerators(next.items);
    items = next.items;
    locale = next.locale;
    if (structureChanged) build();
    else update();
  });
  app.on("browser-window-focus", update);
  app.on("browser-window-blur", update);
  build();
  return { update };
}

import type { SitePermissionMenuWindow } from "../../site-permission-menu-window";
import { BaseWindow, dialog, systemPreferences } from "electron";
import type {
  SitePermissionPlatform,
  SiteMediaPermission,
  SitePermissionChoice,
} from "./site-permissions";

const windowFor = (owner: unknown) =>
  owner instanceof BaseWindow && !owner.isDestroyed() ? owner : undefined;

/** OS consent stays native; website settings use the trusted Comma menu window. */
export function createSitePermissionPlatform(
  locale?: string,
  menu?: SitePermissionMenuWindow
): SitePermissionPlatform {
  const zh = locale === "zh-CN";
  const title = zh ? "网站权限" : "Site permissions";
  const mediaName = (media: SiteMediaPermission) =>
    media === "microphone" ? (zh ? "麦克风" : "Microphone") : zh ? "摄像头" : "Camera";
  const choiceName = (choice: SitePermissionChoice) =>
    ({
      ask: zh ? "每次询问" : "Ask",
      allow: zh ? "允许" : "Allow",
      block: zh ? "阻止" : "Block",
    })[choice];

  const error = (owner: unknown, message: string) => {
    const window = windowFor(owner);
    if (window)
      void dialog
        .showMessageBox(window, { type: "error", title, message })
        .catch(() => undefined);
  };
  return {
    async prompt({ owner, origin, media, signal }) {
      const window = windowFor(owner);
      if (!window || signal.aborted) return "ask";
      const result = await dialog.showMessageBox(window, {
        type: "question",
        title,
        message: zh
          ? `${origin} 请求使用${media.map(mediaName).join("和")}`
          : `${origin} wants to use your ${media.map(mediaName).join(" and ").toLowerCase()}`,
        detail: zh
          ? "选择将仅为此网站保存。可通过地址栏的网站权限修改。"
          : "Your choice is saved for this website. Change it from Site permissions in the address bar.",
        buttons: [
          choiceName("allow"),
          choiceName("block"),
          zh ? "暂不允许" : "Not now",
        ],
        defaultId: 2,
        cancelId: 2,
        noLink: true,
        signal,
      });
      return result.response === 0 ? "allow" : result.response === 1 ? "block" : "ask";
    },
    ...(menu
      ? {
          menu,
          prepare: (owner: unknown) => {
            void menu.prepare(owner).catch(() => undefined);
          },
        }
      : {}),
    settings(input) {
      if (!menu)
        return Promise.reject(new Error("Website permission menu is unavailable."));
      return menu.open(input);
    },
    hasSystemAccess: (media) =>
      process.platform !== "darwin" ||
      systemPreferences.getMediaAccessStatus(media) === "granted",
    async ensureSystemAccess(owner, media) {
      if (process.platform !== "darwin") return true;
      for (const type of media) {
        let status = systemPreferences.getMediaAccessStatus(type);
        if (status === "not-determined") {
          if (await systemPreferences.askForMediaAccess(type)) status = "granted";
        }
        if (status !== "granted") {
          error(
            owner,
            zh
              ? `请在系统设置 → 隐私与安全性 → ${mediaName(type)}中允许 Comma（开发版为 Electron），然后重新加载页面。`
              : `Allow Comma (Electron in development) under System Settings → Privacy & Security → ${mediaName(type)}, then reload the page.`
          );
          return false;
        }
      }
      return true;
    },
    reportError: error,
  };
}

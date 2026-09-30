import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import {
  CommaClientSettingsI18nProvider,
  CommaSessionHostProvider,
  CommaWebClientSettingsProvider,
  TaskPanelApp,
  createWebSessionHostControllerFromAdapter,
  readWebCommaClientSettings,
} from "@comma/app/task-panel";
import { initializeCommaI18n, resolveLocalePreference } from "@comma/i18n";
import "@comma/app/styles.css";

import type { TaskPanelHost } from "@comma/app/task-panel";
import type { WebCookieSessionAdapter } from "@comma/app/task-panel-session";

/** The subset of `Telegram.WebApp` that the Task panel uses. */
export type TelegramApp = {
  initData?: string;
  ready?: () => void;
  colorScheme?: "light" | "dark";
  BackButton?: NonNullable<TaskPanelHost["backButton"]>;
  HapticFeedback?: { selectionChanged?: () => void };
  isVersionAtLeast?: (version: string) => boolean;
  onEvent?: (event: "themeChanged", callback: () => void) => void;
  setBackgroundColor?: (color: string) => void;
  setHeaderColor?: (color: string) => void;
};

export type TaskPanelTarget = {
  groupId: string;
  conversationId: string;
  workspaceId: string;
};

export function renderTaskPanel(
  lifecycle: WebCookieSessionAdapter,
  target: TaskPanelTarget,
  result: "browser" | "signed_in" | "account_mismatch" | "failed",
  telegram?: TelegramApp
) {
  const root = document.getElementById("root");
  if (!root) throw new Error("Root element was not found.");
  const initialSettings = readWebCommaClientSettings();
  const locale = resolveLocalePreference(initialSettings.localePreference);
  initializeCommaI18n([locale]);
  const controller = createWebSessionHostControllerFromAdapter(lifecycle, locale);
  const rootView = createRoot(root);
  const supports = (version: string) => telegram?.isVersionAtLeast?.(version) === true;
  let showingPanel = false;
  if (telegram) {
    syncTelegramChrome(telegram, supports("6.9"));
    // Re-rendering the same tree applies the new scheme without losing panel state.
    telegram.onEvent?.("themeChanged", () => {
      if (showingPanel) renderPanel();
    });
  }

  function renderPanel() {
    showingPanel = true;
    const host: TaskPanelHost | undefined = telegram
      ? {
          colorScheme: telegram.colorScheme,
          backButton: supports("6.1") ? telegram.BackButton : undefined,
          selectionChanged: supports("6.1")
            ? () => telegram.HapticFeedback?.selectionChanged?.()
            : undefined,
        }
      : undefined;
    rootView.render(
      <StrictMode>
        <CommaWebClientSettingsProvider initialSettings={initialSettings}>
          <CommaClientSettingsI18nProvider>
            <CommaSessionHostProvider controller={controller}>
              <TaskPanelApp host={host} target={target} />
            </CommaSessionHostProvider>
          </CommaClientSettingsI18nProvider>
        </CommaWebClientSettingsProvider>
      </StrictMode>
    );
  }

  function renderTelegramFailure(accountMismatch = false) {
    showingPanel = false;
    const chinese = locale.startsWith("zh");
    rootView.render(
      <main className="flex min-h-screen flex-col items-start justify-center gap-xl bg-main-panel-bg p-3xl text-primary">
        <h1 className="text-xl font-semibold">
          {accountMismatch
            ? chinese
              ? "Comma 已登录其他账号"
              : "A different Comma account is signed in"
            : chinese
              ? "无法验证 Telegram 身份"
              : "Telegram sign-in could not be verified"}
        </h1>
        <p className="text-sm text-tertiary">
          {accountMismatch
            ? chinese
              ? "请先在 Comma 中切换账号，再从机器人打开任务面板。"
              : "Switch accounts in Comma, then reopen the Task panel from the bot."
            : chinese
              ? "请重新从机器人打开任务面板，或使用 Comma 账号登录。"
              : "Reopen the Task panel from the bot, or sign in with Comma."}
        </p>
        {accountMismatch ? (
          <a className="text-sm font-medium text-brand-primary" href="/">
            {chinese ? "打开 Comma" : "Open Comma"}
          </a>
        ) : (
          <button
            className="text-sm font-medium text-brand-primary"
            onClick={renderPanel}
            type="button"
          >
            {chinese ? "使用 Comma 登录" : "Sign in with Comma"}
          </button>
        )}
      </main>
    );
  }

  if (result === "signed_in" || result === "browser") renderPanel();
  else renderTelegramFailure(result === "account_mismatch");
}

/** Paint Telegram's header and overscroll area with the panel's own background. */
function syncTelegramChrome(telegram: TelegramApp, supportsHexHeader: boolean) {
  const sync = () => {
    const probe = document.createElement("div");
    probe.style.background = "var(--color-main-panel-bg)";
    document.body.appendChild(probe);
    const color = cssColorToHex(getComputedStyle(probe).backgroundColor);
    probe.remove();
    if (!color) return;
    try {
      telegram.setBackgroundColor?.(color);
      if (supportsHexHeader) telegram.setHeaderColor?.(color);
    } catch {
      // Older clients keep their own chrome colors.
    }
  };
  // The appearance provider writes the resolved theme to the root element.
  new MutationObserver(sync).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme"],
  });
}

function cssColorToHex(color: string): string | undefined {
  const context = document.createElement("canvas").getContext("2d");
  if (!context) return undefined;
  const sentinel = "#010203";
  context.fillStyle = sentinel;
  context.fillStyle = color;
  // An unparsable color leaves the sentinel in place.
  if (context.fillStyle === sentinel) return undefined;
  context.fillRect(0, 0, 1, 1);
  const [red = 0, green = 0, blue = 0, alpha = 0] = context.getImageData(
    0,
    0,
    1,
    1
  ).data;
  if (alpha < 255) return undefined;
  return `#${[red, green, blue].map((value) => value.toString(16).padStart(2, "0")).join("")}`;
}

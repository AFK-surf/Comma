import {
  WebCookieSessionAdapter,
  createBrowserSessionHostPorts,
  defaultApiBaseUrl,
} from "@comma/app/task-panel-session";

import type { TelegramApp } from "./task-panel-view";

const params = new URLSearchParams(location.search);
const target = {
  groupId: params.get("group_id") ?? "",
  conversationId: params.get("conversation_id") ?? "",
  workspaceId: params.get("workspace_id") ?? "",
};
// UI and styles download without delaying authentication or the static first paint.
const viewReady = import("./task-panel-view").catch(() => undefined);

async function start() {
  const lifecycle = new WebCookieSessionAdapter({
    baseUrl: defaultApiBaseUrl(),
    ports: createBrowserSessionHostPorts({
      read: (key) => localStorage.getItem(key),
      write: (key, value) => localStorage.setItem(key, value),
    }),
  });
  const telegram = await (
    window as Window & { commaTelegramReady?: Promise<TelegramApp | undefined> }
  ).commaTelegramReady;
  telegram?.ready?.();
  const result = telegram?.initData
    ? await lifecycle.exchangeTelegramLaunch({
        initData: telegram.initData,
        groupId: target.groupId,
      })
    : "browser";
  const view = await viewReady;
  if (view) view.renderTaskPanel(lifecycle, target, result, telegram);
  else showLoadFailure();
}

function showLoadFailure() {
  const status = document.querySelector("#root output");
  if (!status) return;
  status.textContent = "Task panel could not load. ";
  const retry = document.createElement("button");
  retry.textContent = "Reload";
  retry.addEventListener("click", () => location.reload());
  status.appendChild(retry);
}

void start().catch(showLoadFailure);

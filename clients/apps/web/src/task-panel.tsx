import { defaultApiBaseUrl } from "@comma/app/task-panel-session";
import { connectWebCore } from "./connect-core";

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
  // The client core runs the session: a Telegram launch signs in through it, before the view loads.
  const apiBaseUrl = defaultApiBaseUrl();
  const { core, dispose } = connectWebCore(apiBaseUrl);
  import.meta.hot?.dispose(dispose);
  const telegram = await (
    window as Window & { commaTelegramReady?: Promise<TelegramApp | undefined> }
  ).commaTelegramReady;
  telegram?.ready?.();
  const result = telegram?.initData
    ? ((await core
        .call("session.telegram", {
          initData: telegram.initData,
          groupId: target.groupId,
        })
        .catch(() => "failed")) as "signed_in" | "failed" | "account_mismatch")
    : "browser";
  const view = await viewReady;
  if (view) view.renderTaskPanel(core, apiBaseUrl, target, result, telegram);
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

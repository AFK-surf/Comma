import { useCall, useTopic } from "@comma/core-client";
import { useEffect, useRef, useState } from "react";
import type {
  BrowserViewInput as BrowserInput,
  SessionBrowserBinding as BrowserBinding,
} from "@comma/core/contract";
import { useBrowserStream } from "./useBrowserStream";

const ignore = () => undefined;

/**
 * One viewer's session with an agent's browser: the tab it shows, who controls
 * that tab, and the reader's input while they do. The core reads the tabs,
 * streams the tab and sends the input (`browserView`); the parent keys the
 * viewer by browser, so a different browser mounts a new session.
 */
export function useBrowserSession(
  workspaceId: string,
  binding: BrowserBinding,
  onRefresh: () => void
) {
  const call = useCall();
  const [viewerId] = useState(() => crypto.randomUUID());
  const [browser] = useState(binding);
  const view = {
    workspace: workspaceId,
    agent: browser.agent_id,
    session: browser.session_id,
    viewer: viewerId,
  };
  // The stream stops as soon as the panel closes.
  const { value } = useTopic({ topic: "browserView", ...view }, { lingerMs: 0 });
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  const { canvas, viewport } = useBrowserStream(value?.frame ?? null);
  const controlling = value?.controlling ?? false;

  const command = (
    operation: "take_control" | "return_control" | "close" | "clear_storage"
  ) => {
    void call("browserView.command", { ...view, operation }).then(({ closed }) => {
      if (closed && alive.current) onRefresh();
    }, ignore);
  };

  return {
    browser,
    canvas,
    clearStorage: () => command("clear_storage"),
    closeBrowser: () => command("close"),
    controlling,
    error: value?.error ?? undefined,
    pending: value?.pending ?? false,
    reconnect: () => {
      void call("browserView.reconnect", view).catch(ignore);
      onRefresh();
    },
    selectTab: (tabId: string) => {
      void call("browserView.selectTab", { ...view, tab: tabId }).catch(ignore);
    },
    // Input reaches the tab one command at a time, in order, while this reader
    // still controls the same tab.
    send: (input: BrowserInput) => {
      if (!controlling) return;
      void call("browserView.input", { ...view, input }).catch(ignore);
    },
    // Logins and site storage are shared across the Workspace's tasks unless
    // this browser runs with temporary storage.
    sharedStorage: browser.shared_storage !== false,
    status: value?.status ?? "loading",
    storageError:
      value && "storageError" in value ? value.storageError : binding.storage_error,
    tab: value?.tab ?? "",
    tabs: value?.tabs ?? [],
    toggleControl: () => command(controlling ? "return_control" : "take_control"),
    viewport,
  };
}

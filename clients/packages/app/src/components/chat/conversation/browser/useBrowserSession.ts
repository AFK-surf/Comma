import { useCallback, useEffect, useRef, useState } from "react";
import type { CommaApiClient } from "../../../../api";
import type {
  BrowserBinding,
  BrowserInput,
  BrowserResult,
} from "../../../../api/browser";
import type { BrowserError, BrowserStatus } from "./browserMessages";
import { useBrowserStream } from "./useBrowserStream";

/**
 * One viewer's session with an agent's browser: the tab it shows, who controls
 * that tab, and the reader's input while they do. The parent keys the viewer
 * by browser, so a different browser mounts a new session.
 */
export function useBrowserSession(
  api: CommaApiClient,
  workspaceId: string,
  binding: BrowserBinding,
  onRefresh: () => void
) {
  const [viewerId] = useState(() => crypto.randomUUID());
  const [browser] = useState(binding);
  const [tabs, setTabs] = useState<NonNullable<BrowserResult["tabs"]>>([]);
  const [tab, setTab] = useState("");
  const [status, setStatus] = useState<BrowserStatus>("loading");
  const [error, setError] = useState<BrowserError>();
  const [storageError, setStorageError] = useState(binding.storage_error);
  const [controlling, setControlling] = useState(false);
  const [pending, setPending] = useState(false);
  const [refresh, setRefresh] = useState(0);
  const controlVersion = useRef("");
  const alive = useRef(true);
  const inputQueue = useRef<BrowserInput[]>([]);
  const draining = useRef(false);
  const controls = useRef(false);
  controls.current = controlling;
  const target = useRef("");
  target.current = `${browser?.agent_id}/${browser?.session_id}/${tab}`;
  const clearInput = useCallback(() => {
    inputQueue.current = [];
  }, []);

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
      inputQueue.current = [];
    };
  }, []);

  useEffect(() => {
    controlVersion.current = "";
    setTab("");
    setTabs([]);
    setControlling(false);
    inputQueue.current = [];
    if (!browser) return;
    let current = true;
    api
      .browserCommand(workspaceId, browser, viewerId, "tabs")
      .then((result) => {
        if (!current) return;
        setTabs(result.tabs ?? []);
        setTab(result.tabs?.[0]?.tab_id ?? "");
      })
      .catch(() => {
        if (current) setError("tabs");
      });
    return () => {
      current = false;
    };
  }, [api, workspaceId, browser, viewerId, refresh]);

  const { canvas, viewport } = useBrowserStream({
    api,
    browser,
    clearInput,
    controlVersion,
    refresh,
    setControlling,
    setError,
    setStatus,
    setStorageError,
    tab,
    viewerId,
    workspaceId,
  });

  const command = async (operation: string) => {
    if (!browser || pending) return;
    setPending(true);
    const captured = target.current;
    setError(undefined);
    try {
      const result = await api.browserCommand(
        workspaceId,
        browser,
        viewerId,
        operation,
        {
          tab_id: tab,
        }
      );
      if (alive.current && target.current === captured) {
        controlVersion.current = result.updated_at;
        setControlling(operation === "take_control");
        setStorageError(result.storage_error);
        if (result.status === "closed") onRefresh();
      }
    } catch {
      if (alive.current) setError("control");
    } finally {
      if (alive.current) setPending(false);
    }
  };
  // Input reaches the tab one command at a time, in order, while this reader
  // still controls the same tab.
  const send = (input: BrowserInput) => {
    if (!browser || !controls.current) return;
    if (inputQueue.current.length >= 32) {
      setError("queueFull");
      return;
    }
    inputQueue.current.push(input);
    if (draining.current) return;
    draining.current = true;
    const captured = target.current;
    void (async () => {
      try {
        while (
          alive.current &&
          controls.current &&
          captured === target.current &&
          inputQueue.current.length
        ) {
          const next = inputQueue.current.shift();
          if (!next) break;
          await api.browserCommand(workspaceId, browser, viewerId, "input", {
            tab_id: tab,
            input: next,
          });
        }
      } catch {
        if (alive.current) {
          setControlling(false);
          setError("input");
        }
      } finally {
        inputQueue.current = [];
        draining.current = false;
      }
    })();
  };

  return {
    browser,
    canvas,
    clearStorage: () => void command("clear_storage"),
    closeBrowser: () => void command("close"),
    controlling,
    error,
    pending,
    reconnect: () => {
      setControlling(false);
      inputQueue.current = [];
      setRefresh((value) => value + 1);
      onRefresh();
    },
    selectTab: (tabId: string) => {
      setControlling(false);
      setTab(tabId);
    },
    send,
    // Logins and site storage are shared across the Workspace's tasks unless
    // this browser runs with temporary storage.
    sharedStorage: browser.shared_storage !== false,
    status,
    storageError,
    tab,
    tabs,
    toggleControl: () => void command(controlling ? "return_control" : "take_control"),
    viewport,
  };
}

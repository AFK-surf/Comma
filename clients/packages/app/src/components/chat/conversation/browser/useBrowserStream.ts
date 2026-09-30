import { useEffect, useRef, type RefObject } from "react";
import type { CommaApiClient } from "../../../../api";
import type { BrowserBinding } from "../../../../api/browser";
import type { BrowserViewport } from "./browserInput";
import type { BrowserError, BrowserStatus } from "./browserMessages";

/**
 * Streams the selected tab until the selection changes: who controls the
 * browser, and each frame drawn onto the canvas. A stream that ends reconnects.
 */
export function useBrowserStream({
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
}: {
  api: CommaApiClient;
  browser: BrowserBinding | undefined;
  clearInput: () => void;
  /** The newest control change applied; an older stream event cannot undo it. */
  controlVersion: RefObject<string>;
  refresh: number;
  setControlling: (controlling: boolean) => void;
  setError: (error: BrowserError | undefined) => void;
  setStatus: (status: BrowserStatus) => void;
  setStorageError: (error: string | null | undefined) => void;
  tab: string;
  viewerId: string;
  workspaceId: string;
}) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const viewport = useRef<BrowserViewport>({ width: 1280, height: 720 });
  useEffect(() => {
    if (!browser || !tab) return;
    const abort = new AbortController();
    let drawing = false;
    setError(undefined);
    setStatus("connecting");
    const stream = async () => {
      try {
        while (!abort.signal.aborted) {
          await api.streamBrowser(
            workspaceId,
            browser,
            tab,
            viewerId,
            abort.signal,
            (event) => {
              if (abort.signal.aborted) return;
              if (event.browser.updated_at >= controlVersion.current) {
                controlVersion.current = event.browser.updated_at;
                setStorageError(event.browser.storage_error);
                setControlling(event.can_control);
              }
              setStatus(
                event.browser.control === "human"
                  ? "human"
                  : event.browser.control === "handoff_pending"
                    ? "waiting"
                    : "agent"
              );
              if (!event.frame || drawing) return;
              viewport.current = {
                width: event.frame.metadata.deviceWidth,
                height: event.frame.metadata.deviceHeight,
              };
              drawing = true;
              const image = new Image();
              image.addEventListener("load", () => {
                if (!abort.signal.aborted && canvas.current) {
                  const surface = canvas.current;
                  surface.width = image.naturalWidth;
                  surface.height = image.naturalHeight;
                  surface.style.aspectRatio = `${image.naturalWidth}/${image.naturalHeight}`;
                  surface.getContext("2d")?.drawImage(image, 0, 0);
                }
                drawing = false;
              });
              image.addEventListener("error", () => {
                drawing = false;
              });
              image.src = `data:image/jpeg;base64,${event.frame.data}`;
            }
          );
          if (!abort.signal.aborted)
            await new Promise((resolve) => setTimeout(resolve, 250));
        }
      } catch {
        if (!abort.signal.aborted) {
          setStatus("disconnected");
          setControlling(false);
          setError("stream");
        }
      }
    };
    void stream();
    return () => {
      abort.abort();
      clearInput();
    };
  }, [
    api,
    workspaceId,
    browser,
    tab,
    viewerId,
    refresh,
    clearInput,
    controlVersion,
    setControlling,
    setError,
    setStatus,
    setStorageError,
  ]);
  return { canvas, viewport };
}

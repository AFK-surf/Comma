import { useCallback, useRef, useState } from "react";
import { readChatThreadGeometry } from "./threadGeometry";

export function useThreadElements() {
  // Captured as they mount rather than re-queried: see ChatThreadElements.
  const threadRef = useRef<HTMLDivElement | null>(null);
  const newestTurnAnchorRef = useRef<HTMLElement | null>(null);
  const latestTurnShellRef = useRef<HTMLElement | null>(null);
  const latestTurnBodyRef = useRef<HTMLElement | null>(null);
  // The resize subscription lives in ScrollArea, so the element it has to
  // observe reaches it through a render rather than through the ref.
  const [latestTurnBody, setLatestTurnBody] = useState<HTMLElement | null>(null);
  const registerNewestTurnAnchor = useCallback((node: HTMLElement | null) => {
    newestTurnAnchorRef.current = node;
  }, []);
  const registerLatestTurnShell = useCallback((node: HTMLElement | null) => {
    newestTurnAnchorRef.current = node;
    latestTurnShellRef.current = node;
  }, []);
  const registerLatestTurnBody = useCallback((node: HTMLElement | null) => {
    latestTurnBodyRef.current = node;
    setLatestTurnBody(node);
  }, []);
  const resolveNewestTurn = useCallback(() => newestTurnAnchorRef.current, []);
  const readThreadGeometry = useCallback(
    (viewport: HTMLElement) =>
      readChatThreadGeometry(viewport, {
        latestTurn: latestTurnBodyRef.current,
        latestTurnShell: latestTurnShellRef.current,
        thread: threadRef.current,
      }),
    []
  );
  return {
    latestTurnBody,
    readThreadGeometry,
    registerLatestTurnBody,
    registerLatestTurnShell,
    registerNewestTurnAnchor,
    resolveNewestTurn,
    threadRef,
  };
}

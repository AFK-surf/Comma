import { useEffect, useRef, useState } from "react";
import type {
  ChatImagePreviewRef,
  LocalFilePreview,
} from "../../model/conversationChannel";

const LOCAL_FILE_REF_PATTERN = /^lfi1_[A-Za-z0-9_-]{43}$/;

export type LocalFilePreviewRequest = {
  key: string;
  previewRef: ChatImagePreviewRef;
};

export type LocalFilePreviewState =
  | { status: "loading" }
  | { status: "ready"; url: string }
  | { status: "unavailable" };

export type LocalFilePreviewLoader = (
  previewRef: ChatImagePreviewRef,
  signal?: AbortSignal
) => Promise<LocalFilePreview | undefined>;

export function isLocalFilePreviewRef(value: string) {
  return LOCAL_FILE_REF_PATTERN.test(value);
}

type LiveAcquisition = {
  controller: AbortController;
  preview: LocalFilePreview | undefined;
};

/**
 * Acquires presentation-only preview leases for one mounted UI owner.
 *
 * The loader owns cross-component single-flight and ref counting. This hook
 * owns the React lifetime: every successful acquisition is released when its
 * request disappears, the loader changes, or the
 * component unmounts. Disabling acquisition cancels unfinished work, but a
 * ready image belongs to its mounted presentation, not the scroll position.
 * A result that resolves after its acquisition was
 * retired is released without ever being painted.
 *
 * Request lists change incrementally: a key that stays requested keeps its
 * lease and its state, so dropping one key (a preview that settled without an
 * image) never sends its siblings back through loading.
 */
export function useLocalFilePreviews(
  requests: readonly LocalFilePreviewRequest[],
  loadPreview: LocalFilePreviewLoader | undefined,
  enabled = true
) {
  const [states, setStates] = useState<ReadonlyMap<string, LocalFilePreviewState>>(
    () => new Map()
  );
  const liveRef = useRef(new Map<string, LiveAcquisition>());
  const loaderRef = useRef<LocalFilePreviewLoader | undefined>(undefined);
  const pendingRef = useRef(new Map<string, LocalFilePreviewState>());
  const flushQueuedRef = useRef(false);

  useEffect(() => {
    const live = liveRef.current;
    const retire = (key: string) => {
      const entry = live.get(key);
      if (!entry) return;
      live.delete(key);
      pendingRef.current.delete(key);
      entry.controller.abort();
      entry.preview?.release();
    };

    if (loaderRef.current !== loadPreview) {
      // A different loader means different lease authority: nothing acquired
      // through the previous one may be carried across.
      for (const key of Array.from(live.keys())) retire(key);
      loaderRef.current = loadPreview;
    }

    if (!loadPreview || requests.length === 0) {
      for (const key of Array.from(live.keys())) retire(key);
      pendingRef.current = new Map();
      setStates((current) => (current.size === 0 ? current : new Map()));
      return;
    }

    const wanted = new Set(requests.map((request) => request.key));
    for (const key of Array.from(live.keys())) {
      if (!wanted.has(key) || (!enabled && !live.get(key)?.preview)) retire(key);
    }

    const flushPending = () => {
      flushQueuedRef.current = false;
      const batch = pendingRef.current;
      if (batch.size === 0) return;
      pendingRef.current = new Map();
      setStates((current) => {
        const next = new Map(current);
        for (const [key, state] of batch) {
          if (live.has(key)) next.set(key, state);
        }
        return next;
      });
    };
    const scheduleState = (key: string, state: LocalFilePreviewState) => {
      pendingRef.current.set(key, state);
      if (flushQueuedRef.current) return;
      flushQueuedRef.current = true;
      queueMicrotask(flushPending);
    };

    const added = enabled ? requests.filter((request) => !live.has(request.key)) : [];
    setStates((current) => {
      const next = new Map<string, LocalFilePreviewState>();
      for (const request of requests) {
        const entry = live.get(request.key);
        if (entry?.preview) {
          next.set(request.key, { status: "ready", url: entry.preview.url });
        } else if (enabled) {
          next.set(
            request.key,
            entry
              ? (current.get(request.key) ?? { status: "loading" })
              : { status: "loading" }
          );
        }
      }
      return next;
    });

    for (const request of added) {
      const controller = new AbortController();
      const entry: LiveAcquisition = { controller, preview: undefined };
      live.set(request.key, entry);
      void loadPreview(request.previewRef, controller.signal).then(
        (preview) => {
          if (live.get(request.key) !== entry) {
            preview?.release();
            return;
          }
          entry.preview = preview;
          scheduleState(
            request.key,
            preview ? { status: "ready", url: preview.url } : { status: "unavailable" }
          );
        },
        () => {
          if (live.get(request.key) !== entry) return;
          scheduleState(request.key, { status: "unavailable" });
        }
      );
    }
  }, [enabled, loadPreview, requests]);

  useEffect(() => {
    const live = liveRef.current;
    return () => {
      for (const entry of live.values()) {
        entry.controller.abort();
        entry.preview?.release();
      }
      live.clear();
    };
  }, []);

  return states;
}

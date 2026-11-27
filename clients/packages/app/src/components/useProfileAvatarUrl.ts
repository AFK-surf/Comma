import { useCall, type FileSource } from "@comma/core-client";
import { useEffect, useRef, useState } from "react";
import { readFileBlob } from "../runtime-files/fileSources";

/**
 * The signed-in person's avatar at `avatarRevision`, as the core reads it; none without a revision. The previous
 * image stays while a new revision loads, and its URL is revoked only once nothing shows it.
 */
export function useProfileAvatarUrl(avatarRevision?: string) {
  return useAvatarUrl(
    avatarRevision ? { source: "avatar", revision: avatarRevision } : undefined
  );
}

type Shared = {
  refs: number;
  url: string | undefined;
  read: Promise<string | undefined>;
  controller: AbortController;
};

// One read and one object URL per avatar, shared by every face that shows it (a list may show one person many
// times), per core: a signed-in account's core reads its own. An avatar no face shows any more is let go.
const shared = new WeakMap<object, Map<string, Shared>>();

function hold(call: object, key: string, read: (signal: AbortSignal) => Promise<Blob>) {
  let byKey = shared.get(call);
  if (!byKey) shared.set(call, (byKey = new Map()));
  let entry = byKey.get(key);
  if (!entry) {
    const controller = new AbortController();
    const made: Shared = {
      refs: 0,
      url: undefined,
      controller,
      read: read(controller.signal).then(
        // Let go meanwhile: no URL is made that nothing would revoke.
        (blob) =>
          controller.signal.aborted
            ? undefined
            : (made.url = URL.createObjectURL(blob)),
        () => undefined
      ),
    };
    byKey.set(key, (entry = made));
  }
  entry.refs += 1;
  const held = entry;
  return {
    entry: held,
    release: () => {
      held.refs -= 1;
      if (held.refs > 0) return;
      byKey.delete(key);
      held.controller.abort();
      if (held.url) URL.revokeObjectURL(held.url);
    },
  };
}

/** An avatar the core reads (`source`, by its revision); none without one. */
export function useAvatarUrl(source: FileSource | undefined) {
  const call = useCall();
  const key = source ? JSON.stringify(source) : undefined;
  const [url, setUrl] = useState<string>();
  // The avatar on show, held until the next one is read: a new revision does not blank it meanwhile.
  const showing = useRef<(() => void) | undefined>(undefined);

  useEffect(() => {
    if (!key) {
      showing.current?.();
      showing.current = undefined;
      setUrl(undefined);
      return;
    }
    const { entry, release } = hold(call, key, (signal) =>
      readFileBlob(call, JSON.parse(key) as FileSource, signal)
    );
    let live = true;
    const show = (made: string | undefined) => {
      if (!live) return;
      showing.current?.();
      showing.current = release;
      setUrl(made);
    };
    if (entry.url) show(entry.url);
    else void entry.read.then(show);
    return () => {
      live = false;
      // Not shown yet: let it go now. Shown: it goes when the next one shows, or below on unmount.
      if (showing.current !== release) release();
    };
  }, [key, call]);

  useEffect(
    () => () => {
      showing.current?.();
      showing.current = undefined;
    },
    []
  );

  return key ? url : undefined;
}

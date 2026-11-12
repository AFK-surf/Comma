import { useCall, type FileSource } from "@comma/core-client";
import { useEffect, useState } from "react";
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

/** An avatar the core reads (`source`, by its revision); none without one. */
export function useAvatarUrl(source: FileSource | undefined) {
  const call = useCall();
  const [url, setUrl] = useState<string>();
  const key = source ? JSON.stringify(source) : undefined;

  useEffect(() => {
    if (!key) {
      setUrl(undefined);
      return;
    }

    const controller = new AbortController();
    void readFileBlob(call, JSON.parse(key) as FileSource, controller.signal)
      .then((blob) => {
        if (!controller.signal.aborted) setUrl(URL.createObjectURL(blob));
      })
      .catch(() => {
        if (!controller.signal.aborted) setUrl(undefined);
      });

    return () => controller.abort();
  }, [key, call]);

  useEffect(() => {
    if (!url) return;
    return () => URL.revokeObjectURL(url);
  }, [url]);

  return url;
}

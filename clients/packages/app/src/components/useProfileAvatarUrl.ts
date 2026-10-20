import { useCall } from "@comma/core-client";
import { useEffect, useState } from "react";
import { readFileBlob } from "../runtime-files/fileSources";

/**
 * The signed-in person's avatar at `avatarRevision`, as the core reads it; none without a revision. The previous
 * image stays while a new revision loads, and its URL is revoked only once nothing shows it.
 */
export function useProfileAvatarUrl(avatarRevision?: string) {
  const call = useCall();
  const [url, setUrl] = useState<string>();

  useEffect(() => {
    if (!avatarRevision) {
      setUrl(undefined);
      return;
    }

    const controller = new AbortController();
    void readFileBlob(
      call,
      { source: "avatar", revision: avatarRevision },
      controller.signal
    )
      .then((blob) => {
        if (!controller.signal.aborted) setUrl(URL.createObjectURL(blob));
      })
      .catch(() => {
        if (!controller.signal.aborted) setUrl(undefined);
      });

    return () => controller.abort();
  }, [avatarRevision, call]);

  useEffect(() => {
    if (!url) return;
    return () => URL.revokeObjectURL(url);
  }, [url]);

  return url;
}

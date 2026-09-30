import { useContext, useEffect, useState } from "react";
import { CommaAuthContext } from "./auth-context";

export function useProfileAvatarUrl(avatarRevision?: string) {
  const api = useContext(CommaAuthContext)?.api;
  const [url, setUrl] = useState<string>();

  useEffect(() => {
    if (!api || !avatarRevision) {
      setUrl(undefined);
      return;
    }

    const controller = new AbortController();
    let objectUrl: string | undefined;

    void api
      .fetchAvatar(avatarRevision, { signal: controller.signal })
      .then((blob) => {
        if (controller.signal.aborted) return;
        objectUrl = URL.createObjectURL(blob);
        setUrl(objectUrl);
      })
      .catch(() => {
        if (!controller.signal.aborted) setUrl(undefined);
      });

    return () => {
      controller.abort();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [api, avatarRevision]);

  return url;
}

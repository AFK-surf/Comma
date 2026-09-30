import { useEffect, useState } from "react";

/**
 * One object URL per blob, created and revoked by the same effect.
 * The renderer runs under StrictMode in development, which mounts, unmounts and
 * remounts once: a URL minted in render or `useMemo` survives that cycle while
 * its cleanup has already revoked it, and every `<img>` then 404s on it.
 */
export function useDriveObjectUrl(blob: Blob | undefined) {
  const [url, setUrl] = useState<string>();
  useEffect(() => {
    if (!blob) {
      setUrl(undefined);
      return undefined;
    }
    const objectUrl = URL.createObjectURL(blob);
    setUrl(objectUrl);
    return () => {
      URL.revokeObjectURL(objectUrl);
    };
  }, [blob]);
  return url;
}

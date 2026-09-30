import { useEffect, useState } from "react";

export type Resource<T> =
  | { status: "loading" }
  | { status: "ready"; data: T }
  | { status: "error"; error: string };

export function useResource<T>(
  loader: () => Promise<T>,
  dependencies: unknown[]
): Resource<T> {
  const [resource, setResource] = useState<Resource<T>>({ status: "loading" });

  useEffect(() => {
    let active = true;
    setResource({ status: "loading" });
    loader().then(
      (data) => active && setResource({ status: "ready", data }),
      (error: unknown) =>
        active &&
        setResource({
          status: "error",
          error: error instanceof Error ? error.message : String(error),
        })
    );
    return () => {
      active = false;
    };
    // The caller controls when its loader should be refreshed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, dependencies);

  return resource;
}

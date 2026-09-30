import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { createBftApi, type BftApi } from "./api";

export const ApiContext = createContext<BftApi>(createBftApi());

export const useApi = () => useContext(ApiContext);

export type Resource<T> =
  | { state: "loading" }
  | { state: "ready"; data: T }
  | { state: "error"; error: unknown };

/** Loads `key` with `load`; a new key or `retry()` starts over. */
export function useResource<T>(
  key: string,
  load: (signal: AbortSignal) => Promise<T>
): [Resource<T>, () => void] {
  const [attempt, setAttempt] = useState(0);
  const [resource, setResource] = useState<Resource<T> & { key: string }>({
    key,
    state: "loading",
  });

  useEffect(() => {
    const controller = new AbortController();
    setResource({ key, state: "loading" });
    load(controller.signal).then(
      (data) => {
        if (!controller.signal.aborted) setResource({ key, state: "ready", data });
      },
      (error: unknown) => {
        if (!controller.signal.aborted) setResource({ key, state: "error", error });
      }
    );
    return () => controller.abort();
    // `load` is keyed by `key`; callers pass inline closures.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, attempt]);

  const retry = useCallback(() => setAttempt((value) => value + 1), []);
  return [resource.key === key ? resource : { state: "loading" }, retry];
}

import { useEffect, useRef, useState } from "react";
import {
  getNativeBridge,
  type LocalStationAccounts,
  type LocalStationAccountSource,
  type LocalStationRuntime,
  type LocalStationRuntimeAccounts,
} from "@comma/native-bridge";

export type MachineAccountRuntime = LocalStationRuntime;

/** The station did not allow the change in its current state (409): its view is read again, not an error. */
const conflicted = (reason: unknown) =>
  !!reason &&
  typeof reason === "object" &&
  "bridgeError" in reason &&
  (reason.bridgeError as { code?: string } | undefined)?.code ===
    "LOCAL_STATION_CONFLICT";

/**
 * Which account this Mac's Codex and Claude Code run on in `workspace` (or a model server on this Mac), and signing one
 * in, over this Mac's station's local admin interface (Main's `localStation` capabilities). One read on entry and one on window focus (coming back
 * from the browser reads how a sign-in went), and one mutation per explicit choice. No polling.
 */
export function useMachineAccounts(workspace: string | undefined) {
  const bridge = getNativeBridge();
  const [view, setView] = useState<LocalStationAccounts>();
  const [pending, setPending] = useState(false);
  /** What failed last: reading the station, or saving a choice (its state was read again after). */
  const [problem, setProblem] = useState<"read" | "save">();
  const revision = useRef({ value: 0 });
  const writing = useRef(false);
  const read = useRef<() => Promise<void>>(async () => undefined);

  useEffect(() => {
    setView(undefined);
    setProblem(undefined);
    if (!workspace) return undefined;
    const requests = revision.current;
    const refresh = async () => {
      if (writing.current) return;
      const at = ++revision.current.value;
      try {
        const value = await bridge.localStation.accounts();
        if (at !== revision.current.value) return;
        setView(value);
        setProblem(undefined);
      } catch {
        if (at === revision.current.value) setProblem("read");
      }
    };
    read.current = refresh;
    void refresh();
    window.addEventListener("focus", refresh);
    return () => {
      requests.value++;
      read.current = async () => undefined;
      window.removeEventListener("focus", refresh);
    };
  }, [bridge, workspace]);

  /** One mutation; after a failed or uncertain one the station's actual state is read before another edit. */
  const write = async (mutate: () => Promise<LocalStationAccounts>) => {
    if (!workspace || writing.current) return false;
    writing.current = true;
    const at = ++revision.current.value;
    setPending(true);
    setProblem(undefined);
    try {
      const value = await mutate();
      if (at === revision.current.value) setView(value);
      return true;
    } catch (reason) {
      // A response can be lost after the station saved the choice: read what it holds.
      try {
        const value = await bridge.localStation.accounts();
        if (at === revision.current.value) {
          setView(value);
          if (!conflicted(reason)) setProblem("save");
        }
      } catch {
        if (at === revision.current.value) setProblem("read");
      }
      return false;
    } finally {
      writing.current = false;
      if (at === revision.current.value) setPending(false);
    }
  };

  const accounts: Record<LocalStationRuntime, LocalStationRuntimeAccounts> | undefined =
    view?.workspaces.find((entry) => entry.workspaceId === workspace)?.runtimes;

  const change = (runtime: LocalStationRuntime, source: LocalStationAccountSource) =>
    void write(() =>
      bridge.localStation.setAccountSource({ workspaceId: workspace!, runtime, source })
    );
  // A model server on this Mac: the station checks it before it answers, and the row says how that went.
  const setEndpoint = (runtime: LocalStationRuntime, endpoint: string, key: string) =>
    write(() =>
      bridge.localStation.setAccountSource({
        workspaceId: workspace!,
        runtime,
        source: "endpoint",
        endpoint,
        ...(key ? { key } : {}),
      })
    );
  // The station runs the CLI's own login command; the CLI opens its page in the browser here. Coming back from the
  // browser (focus) reads how it went.
  const signIn = (runtime: LocalStationRuntime) =>
    void write(() => bridge.localStation.signIn({ workspaceId: workspace!, runtime }));
  const stopSignIn = (runtime: LocalStationRuntime) =>
    void write(() =>
      bridge.localStation.stopSignIn({ workspaceId: workspace!, runtime })
    );

  return {
    accounts,
    /** The station answered, but it does not know this workspace. */
    missing: view !== undefined && accounts === undefined,
    pending,
    problem,
    change,
    setEndpoint,
    signIn,
    stopSignIn,
    retry: () => void read.current(),
  };
}

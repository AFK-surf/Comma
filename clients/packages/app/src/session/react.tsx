import { createContext, useContext, useSyncExternalStore, type ReactNode } from "react";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";
import type { SessionHostController } from "./controller";

const SessionHostContext = createContext<SessionHostController | undefined>(undefined);

export function CommaSessionHostProvider({
  children,
  controller,
}: {
  children: ReactNode;
  controller: SessionHostController;
}) {
  return (
    <SessionHostContext.Provider value={controller}>
      {children}
    </SessionHostContext.Provider>
  );
}

export function useSessionHostController() {
  const controller = useContext(SessionHostContext);
  if (!controller) {
    throw new Error(
      "The Session host controller is unavailable. Each production host must inject its real credential-authority adapter."
    );
  }
  return controller;
}

export interface SessionLifecycleProjectionSource {
  getSnapshotSync(): SessionLifecycleSnapshot;
  subscribe(listener: (snapshot: SessionLifecycleSnapshot) => void): () => void;
}

export function useSessionLifecycleSnapshot(source: SessionLifecycleProjectionSource) {
  return useSyncExternalStore(
    (listener) => source.subscribe(() => listener()),
    () => source.getSnapshotSync(),
    () => source.getSnapshotSync()
  );
}

export type {
  SessionAuthenticatorController,
  SessionGuestController,
  SessionHostController,
  SessionLifecycleController,
  SessionLoginChallenge,
} from "./controller";
export type { WebSessionHostPorts } from "./web/coordination-ports";

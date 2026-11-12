import { createContext, useContext, useSyncExternalStore, type ReactNode } from "react";
import type { SessionLifecycleSnapshot } from "@comma/session-contract";
import type { SessionHostController, SessionKeptAccount } from "./controller";

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

const noAccounts: readonly SessionKeptAccount[] = [];
const noChanges = () => () => undefined;

/** The accounts kept signed in besides the one in use (none where the host keeps one). */
export function useSessionKeptAccounts(controller: SessionHostController) {
  const accounts = controller.accounts;
  return useSyncExternalStore(
    accounts ? accounts.subscribe : noChanges,
    () => accounts?.get() ?? noAccounts,
    () => accounts?.get() ?? noAccounts
  );
}

export type {
  SessionAccountsController,
  SessionKeptAccount,
  SessionAuthenticatorController,
  SessionGuestController,
  SessionHostController,
  SessionLifecycleController,
  SessionLoginChallenge,
  SessionLoginTiming,
} from "./controller";

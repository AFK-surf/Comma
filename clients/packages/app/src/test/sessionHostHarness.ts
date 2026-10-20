import type {
  SessionLifecycleSnapshot,
  TerminalSessionSnapshot,
} from "@comma/session-contract";
import type { CommaApiSessionTransport } from "../session/controller";
import type { SessionHostController } from "../session/controller";

const testSessionPublishers = new WeakMap<
  SessionHostController,
  (next: SessionLifecycleSnapshot) => void
>();

export function createTestSessionHostController({
  apiBaseUrl = "assets://.",
  bumpGenerationOnReconcile = false,
  initial,
  onSignOut,
}: {
  apiBaseUrl?: string;
  bumpGenerationOnReconcile?: boolean;
  initial: TerminalSessionSnapshot;
  onSignOut?: () => Promise<TerminalSessionSnapshot>;
}): SessionHostController {
  let snapshot: SessionLifecycleSnapshot = initial;
  let recovery: "trying" | "exhausted" | null = null;
  const recoveryListeners = new Set<() => void>();
  let recovers = 0;
  const listeners = new Set<(value: SessionLifecycleSnapshot) => void>();
  const signal = new AbortController().signal;
  const transport: CommaApiSessionTransport = {
    credentials: "omit",
    signal,
    applyHeaders: () => undefined,
    reportSessionRejection: () => undefined,
  };
  const publish = (next: SessionLifecycleSnapshot) => {
    snapshot = next;
    for (const listener of listeners) {
      listener(next);
    }
  };

  const controller: SessionHostController = {
    apiBaseUrl,
    authenticator: {
      cancelCurrentAttempt: async () => undefined,
      mountGoogleControl: async () => () => undefined,
      requestEmailLogin: async () => {
        throw new Error("Test Session authenticator is unavailable.");
      },
      verifyEmailLogin: async () => undefined,
      verifyGoogleLink: async () => undefined,
    },
    getProductTransport: () => (snapshot.phase === "signed_in" ? transport : undefined),
    initialize: async () => undefined,
    lifecycle: {
      getSnapshot: async () => snapshot,
      getSnapshotSync: () => snapshot,
      reconcile: async () => {
        if (bumpGenerationOnReconcile && snapshot.phase === "signed_in") {
          const next: TerminalSessionSnapshot = {
            ...snapshot,
            generation: snapshot.generation + 1,
            revision: snapshot.revision + 1,
          };
          publish(next);
          return { ok: true, value: next };
        }
        return {
          ok: true,
          value: snapshot as TerminalSessionSnapshot,
        };
      },
      signOut: async () => {
        const next = onSignOut ? await onSignOut() : signedOutSessionSnapshot;
        publish(next);
        return { ok: true, value: next };
      },
      subscribe: (listener) => {
        listeners.add(listener);
        listener(snapshot);
        return () => listeners.delete(listener);
      },
    },
    connectionRecovery: {
      get: () => recovery,
      subscribe: (listener) => {
        recoveryListeners.add(listener);
        return () => void recoveryListeners.delete(listener);
      },
    },
    recover: async () => {
      recovers += 1;
    },
  };
  testSessionPublishers.set(controller, publish);
  testRecoveries.set(controller, {
    set(next) {
      recovery = next;
      for (const listener of Array.from(recoveryListeners)) listener();
    },
    recovers: () => recovers,
  });
  return controller;
}

const testRecoveries = new WeakMap<
  SessionHostController,
  { set(next: "trying" | "exhausted" | null): void; recovers(): number }
>();

/** The core's connection recovery as a test scripts it: what the window is told, and how often it asked again. */
export function testConnectionRecovery(controller: SessionHostController) {
  return testRecoveries.get(controller)!;
}

export function publishTestSessionSnapshot(
  controller: SessionHostController,
  next: SessionLifecycleSnapshot
) {
  const publish = testSessionPublishers.get(controller);
  if (!publish) {
    throw new Error("publishTestSessionSnapshot requires a test Session host.");
  }
  publish(next);
}

export const signedOutSessionSnapshot: TerminalSessionSnapshot = {
  authority: {
    authorityInstanceId: "test-electron-main",
    kind: "electron_main",
  },
  cleanup: { revocation: "idle" },
  contractVersion: 1,
  generation: 0,
  phase: "signed_out",
  principal: null,
  reason: "no_session",
  revision: 1,
  session: null,
};

export const signedInSessionSnapshot = {
  authority: {
    authorityInstanceId: "test-electron-main",
    kind: "electron_main",
  },
  cleanup: { revocation: "idle" },
  contractVersion: 1,
  generation: 1,
  phase: "signed_in",
  principal: {
    email: "person@example.com",
    userId: "usr_1",
  },
  revision: 1,
  session: {
    audience: "https://api.comma.test",
    expiresAtEpochSeconds: 2_000_000_000,
    sessionId: "11111111-1111-4111-8111-111111111111",
  },
} satisfies TerminalSessionSnapshot;

import type {
  SessionLifecycleExpectation,
  SessionLifecycleSnapshot,
  SessionOperationResult,
  TerminalSessionSnapshot,
} from "@comma/session-contract";
import type { CommaApiSessionTransport } from "../api";

export type SessionLoginChallenge = {
  challengeId: string;
  code?: string | undefined;
  email?: string | undefined;
  kind: "challenge";
  purpose: "email_login" | "google_link";
};

export interface SessionAuthenticatorController {
  cancelCurrentAttempt(): Promise<void>;
  mountGoogleControl(input: {
    element: HTMLElement;
    onError(error: Error): void;
    onResult(result: { kind: "signed_in" } | SessionLoginChallenge): void;
  }): Promise<() => void>;
  /**
   * Starts Google sign-in directly, without mounting a provider-rendered
   * control. Present only on hosts (Electron Main) that own the OAuth flow
   * natively; browser hosts must keep using {@link mountGoogleControl}.
   */
  requestGoogleLogin?(input: {
    onError(error: Error): void;
    onResult(result: { kind: "signed_in" } | SessionLoginChallenge): void;
  }): Promise<void>;
  requestEmailLogin(email: string): Promise<SessionLoginChallenge>;
  verifyEmailLogin(input: { challengeId: string; code: string }): Promise<void>;
  verifyGoogleLink(input: { challengeId: string; code: string }): Promise<void>;
}

export interface SessionLifecycleController {
  getSnapshot(): Promise<SessionLifecycleSnapshot>;
  getSnapshotSync(): SessionLifecycleSnapshot;
  reconcile(input: {
    expected?: SessionLifecycleExpectation;
    reason: "focus" | "manual_retry" | "peer_mutation" | "startup";
  }): Promise<SessionOperationResult<TerminalSessionSnapshot, "reconcile">>;
  signOut(input: { expected: SessionLifecycleExpectation }): Promise<unknown>;
  subscribe(listener: (snapshot: SessionLifecycleSnapshot) => void): () => void;
}

export interface SessionHostController {
  readonly apiBaseUrl: string;
  readonly authenticator: SessionAuthenticatorController;
  readonly lifecycle: SessionLifecycleController;
  dispose?(): void;
  getProductTransport(): CommaApiSessionTransport | undefined;
  initialize(): Promise<void>;
  recover(): Promise<void>;
}

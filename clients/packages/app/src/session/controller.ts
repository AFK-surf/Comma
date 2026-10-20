import type {
  SessionLifecycleExpectation,
  SessionLifecycleSnapshot,
  SessionOperationResult,
  TerminalSessionSnapshot,
} from "@comma/session-contract";

/**
 * How a product request carries the current session: the credentials mode, the
 * lease's abort signal, its headers, and where a 401/409 rejection is reported.
 */
export interface CommaApiSessionTransport {
  readonly credentials: RequestCredentials;
  readonly signal: AbortSignal;
  applyHeaders(headers: Record<string, string>): void;
  reportSessionRejection(status: 401 | 409): void;
}

export type SessionLoginChallenge = {
  challengeId: string;
  code?: string | undefined;
  email?: string | undefined;
  kind: "challenge";
  purpose: "email_login" | "google_link" | "apple_link";
};

/** The countdowns a login screen shows, as the session's authority counts them on its clock. */
export type SessionLoginTiming = {
  /** The emailed code under way: whether it stopped working, and seconds until another may be sent. */
  challenge?: {
    challengeId: string;
    expired: boolean;
    resendInSeconds: number;
    /** The last code checked got no answer about the code (unreachable): the same code may be sent again. */
    retrySameCode?: boolean;
  };
  /** An address that must wait before a code is requested, and for how many seconds. */
  cooldown?: { email: string; seconds: number };
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
  /**
   * Emails a code. The address of the code under way, while it still works, goes back to that code without a new one
   * (the core decides) unless `resend` asks for another.
   */
  requestEmailLogin(
    email: string,
    options?: { resend?: true }
  ): Promise<SessionLoginChallenge>;
  /**
   * The code the session's sign-in under way waits for, whichever window started it (the web, where every tab shows
   * the client core's one sign-in). A login screen continues it, and leaves it when it is gone.
   */
  readonly sharedChallenge?: {
    get(): SessionLoginChallenge | undefined;
    subscribe(listener: () => void): () => void;
  };
  /** The login screen's countdowns, where the authority counts them (the client core); absent: none. */
  readonly loginTiming?: {
    get(): SessionLoginTiming;
    subscribe(listener: () => void): () => void;
  };
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

/**
 * Guest mode: a server-issued Session for a throwaway guest account. The host
 * keeps the sign-up claim; renderers never read it.
 */
export interface SessionGuestController {
  /** Whether the server offers guest sessions. Resolves false on failure. */
  availability(): Promise<boolean>;
  /** Ends the current guest Session so the next sign-in imports its chat. */
  beginSignUp(): Promise<void>;
  /** Starts a guest Session and replaces any pending sign-in attempt. */
  start(): Promise<void>;
  /** Notifies after a sign-in imported the previous guest chat. */
  subscribeImported(listener: () => void): () => void;
}

export interface SessionHostController {
  readonly apiBaseUrl: string;
  readonly authenticator: SessionAuthenticatorController;
  readonly guest?: SessionGuestController | undefined;
  readonly lifecycle: SessionLifecycleController;
  /**
   * The connection recovery the session's authority runs (the client core), on its clock: `trying` through its burst,
   * `exhausted` once it stopped until `recover()`; null while none is needed.
   */
  readonly connectionRecovery: {
    get(): "trying" | "exhausted" | null;
    subscribe(listener: () => void): () => void;
  };
  dispose?(): void;
  getProductTransport(): CommaApiSessionTransport | undefined;
  initialize(): Promise<void>;
  recover(): Promise<void>;
}

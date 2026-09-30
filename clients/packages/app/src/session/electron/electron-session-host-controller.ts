import { baseLocale, messages, type CommaLocale } from "@comma/i18n";
import { getNativeBridge, type SessionBridge } from "@comma/native-bridge";
import {
  createSessionProblem,
  encodeSessionPresenceExpectation,
  mergeSessionSnapshot,
  sessionExpectation,
  sessionLifecycleSnapshotSchema,
  sessionPresenceExpectationHeader,
  type SessionAbsenceExpectation,
  type SessionAuthAttemptRef,
  type SessionLifecycleExpectation,
  type SessionLifecycleSnapshot,
  type SessionPresenceExpectation,
  type SignedInSessionSnapshot,
} from "@comma/session-contract";
import type { CommaApiSessionTransport } from "../../api";
import type {
  SessionAuthenticatorController,
  SessionHostController,
  SessionLifecycleController,
  SessionLoginChallenge,
} from "../controller";
import { sessionOperationDisplayError } from "../operation-error-message";

export function createElectronSessionHostController(input?: {
  bridge?: SessionBridge;
  locale?: CommaLocale;
}): SessionHostController {
  return new ElectronSessionHostController(
    input?.bridge ?? getNativeBridge().session,
    input?.locale ?? baseLocale
  );
}

const electronMainProxyBaseUrl = "assets://.";

type ElectronProductTransportRecord = {
  controller: AbortController;
  expectation: SessionPresenceExpectation;
  identity: string;
  transport: CommaApiSessionTransport;
};

class ElectronSessionHostController implements SessionHostController {
  readonly apiBaseUrl = electronMainProxyBaseUrl;
  readonly authenticator: SessionAuthenticatorController;
  readonly lifecycle: SessionLifecycleController;
  private readonly bridge: SessionBridge;
  private readonly listeners = new Set<(snapshot: SessionLifecycleSnapshot) => void>();
  private productTransport: ElectronProductTransportRecord | undefined;
  private rejectedProduct: { identity: string } | undefined;
  private snapshot = uninitializedElectronSnapshot();
  private unsubscribeBridge: () => void;

  constructor(bridge: SessionBridge, locale: CommaLocale) {
    this.bridge = bridge;
    this.authenticator = new ElectronSessionAuthenticator(
      bridge,
      () => this.getSnapshotSync(),
      locale
    );
    this.lifecycle = {
      getSnapshot: async () => {
        const snapshot = await this.bridge.state.get();
        this.acceptSnapshot(snapshot);
        return this.snapshot;
      },
      getSnapshotSync: () => this.snapshot,
      reconcile: async (input) => {
        const result = await this.bridge.reconcile(input);
        if (result.ok) {
          this.acceptSnapshot(result.value);
        } else {
          await this.refreshAfterCommand();
        }
        return result;
      },
      signOut: async (input) => {
        const result = await this.bridge.signOut(input);
        if (result.ok) {
          this.acceptSnapshot(result.value);
        } else {
          await this.refreshAfterCommand();
        }
        return result;
      },
      subscribe: (listener) => {
        this.listeners.add(listener);
        listener(this.snapshot);
        return () => {
          this.listeners.delete(listener);
        };
      },
    };
    this.unsubscribeBridge = bridge.state.subscribe((snapshot) => {
      this.acceptSnapshot(snapshot);
    });
  }

  dispose() {
    this.productTransport?.controller.abort();
    this.productTransport = undefined;
    this.unsubscribeBridge();
    this.listeners.clear();
  }

  getProductTransport() {
    if (this.snapshot.phase !== "signed_in") {
      return undefined;
    }

    const expectation = signedInExpectation(this.snapshot);
    const identity = productExpectationIdentity(expectation);
    if (this.rejectedProduct?.identity === identity) {
      return undefined;
    }
    if (
      this.productTransport?.identity === identity &&
      !this.productTransport.controller.signal.aborted
    ) {
      return this.productTransport.transport;
    }

    this.productTransport?.controller.abort();
    const controller = new AbortController();
    const serializedExpectation = encodeSessionPresenceExpectation(expectation);
    const record = {} as ElectronProductTransportRecord;
    const transport: CommaApiSessionTransport = {
      credentials: "omit",
      signal: controller.signal,
      applyHeaders(headers) {
        headers[sessionPresenceExpectationHeader] = serializedExpectation;
      },
      reportSessionRejection: (status) => {
        this.reportProductRejection(record, status);
      },
    };
    Object.assign(record, {
      controller,
      expectation,
      identity,
      transport,
    });
    this.productTransport = record;
    return transport;
  }

  async initialize() {
    const snapshot = await this.bridge.state.get();
    this.acceptSnapshot(snapshot);
    if (snapshot.phase === "initializing") {
      const result = await this.bridge.reconcile({ reason: "startup" });
      if (result.ok) {
        this.acceptSnapshot(result.value);
      } else {
        await this.refreshAfterCommand();
      }
    }
  }

  async recover() {
    const snapshot = await this.bridge.state.get();
    this.acceptSnapshot(snapshot);
    const expected = recoveryExpectation(snapshot);
    if (!expected && snapshot.phase !== "indeterminate") return;
    const result = await this.bridge.reconcile({
      ...(expected ? { expected } : {}),
      reason: "manual_retry",
    });
    if (result.ok) {
      this.acceptSnapshot(result.value);
    } else {
      await this.refreshAfterCommand();
    }
  }

  private getSnapshotSync() {
    return this.snapshot;
  }

  private acceptSnapshot(
    value: unknown,
    options: { settledRejectedIdentity?: string | undefined } = {}
  ) {
    const incoming = sessionLifecycleSnapshotSchema.parse(value);
    const merge = mergeSessionSnapshot(this.snapshot, incoming, {
      trustedAuthorityRebind:
        this.snapshot.authority.authorityInstanceId ===
        "electron-renderer-uninitialized",
    });
    if (!merge.accepted) {
      if (
        options.settledRejectedIdentity &&
        options.settledRejectedIdentity === this.rejectedProduct?.identity &&
        signedInSnapshotIdentity(incoming) === options.settledRejectedIdentity
      ) {
        this.rejectedProduct = undefined;
        this.snapshot = { ...this.snapshot };
        this.notifySnapshotListeners();
      }
      return;
    }
    const previousIdentity = signedInSnapshotIdentity(this.snapshot);
    const nextIdentity = signedInSnapshotIdentity(merge.snapshot);
    if (previousIdentity !== nextIdentity || nextIdentity === undefined) {
      this.productTransport?.controller.abort();
      this.productTransport = undefined;
      this.rejectedProduct = undefined;
    } else if (options.settledRejectedIdentity === nextIdentity) {
      this.rejectedProduct = undefined;
    }
    this.snapshot = merge.snapshot;
    this.notifySnapshotListeners();
  }

  private notifySnapshotListeners() {
    for (const listener of this.listeners) {
      listener(this.snapshot);
    }
  }

  private reportProductRejection(
    record: ElectronProductTransportRecord,
    _status: 401 | 409
  ) {
    if (
      this.productTransport !== record ||
      record.controller.signal.aborted ||
      signedInSnapshotIdentity(this.snapshot) !== record.identity
    ) {
      return;
    }

    record.controller.abort();
    this.productTransport = undefined;
    this.rejectedProduct = {
      identity: record.identity,
    };
    void this.bridge
      .reconcile({
        expected: record.expectation,
        reason: "peer_mutation",
      })
      .then(async (result) => {
        if (result.ok) {
          this.acceptSnapshot(result.value, {
            settledRejectedIdentity: record.identity,
          });
        } else {
          await this.refreshAfterCommand();
        }
      })
      .catch(async () => {
        await this.refreshAfterCommand().catch(() => undefined);
      });
  }

  private async refreshAfterCommand() {
    this.acceptSnapshot(await this.bridge.state.get());
  }
}

type ElectronActiveAttempt = {
  attempt: SessionAuthAttemptRef;
  purpose: SessionLoginChallenge["purpose"];
};

class ElectronSessionAuthenticator implements SessionAuthenticatorController {
  private activeAttempt: ElectronActiveAttempt | undefined;
  private pendingGoogle: { expected: SessionAbsenceExpectation } | undefined;

  constructor(
    private readonly bridge: SessionBridge,
    private readonly getSnapshot: () => SessionLifecycleSnapshot,
    private readonly locale: CommaLocale
  ) {}

  async requestEmailLogin(email: string): Promise<SessionLoginChallenge> {
    const previousAttempt = this.activeAttempt;
    const expected =
      this.pendingGoogle?.expected ??
      (previousAttempt
        ? this.requireAttempt("email_login").attempt.expected
        : this.currentAbsenceExpectation());
    this.pendingGoogle = undefined;
    const result = await this.bridge.requestEmailLogin({
      email,
      expected,
    });
    if (!result.ok) {
      await this.synchronizeAttemptAfterFailure(result.error.code, previousAttempt);
      throw sessionOperationError(result.error.code, this.locale);
    }
    this.activeAttempt = {
      attempt: result.value.attempt,
      purpose: "email_login",
    };
    return {
      challengeId: result.value.challengeId,
      kind: "challenge",
      purpose: "email_login",
    };
  }

  async verifyEmailLogin(input: { challengeId: string; code: string }) {
    const active = this.requireAttempt("email_login");
    const result = await this.bridge.verifyEmailLogin({
      attempt: active.attempt,
      challengeId: input.challengeId,
      code: input.code,
    });
    if (!result.ok) {
      await this.synchronizeAttemptAfterFailure(result.error.code, active);
      throw sessionOperationError(result.error.code, this.locale);
    }
    this.activeAttempt = undefined;
  }

  async verifyGoogleLink(input: { challengeId: string; code: string }) {
    const active = this.requireAttempt("google_link");
    const result = await this.bridge.verifyGoogleLink({
      attempt: active.attempt,
      challengeId: input.challengeId,
      code: input.code,
    });
    if (!result.ok) {
      await this.synchronizeAttemptAfterFailure(result.error.code, active);
      throw sessionOperationError(result.error.code, this.locale);
    }
    this.activeAttempt = undefined;
  }

  async cancelCurrentAttempt() {
    const attempt = this.activeAttempt;
    if (!attempt) {
      return;
    }
    const result = await this.bridge.cancelAuthAttempt({ attempt: attempt.attempt });
    if (!result.ok && result.error.code !== "conflict") {
      throw sessionOperationError(result.error.code, this.locale);
    }
    if (this.activeAttempt === attempt) {
      this.activeAttempt = undefined;
    }
  }

  async requestGoogleLogin(input: {
    onError(error: Error): void;
    onResult(result: { kind: "signed_in" } | SessionLoginChallenge): void;
  }) {
    await this.signInWithGoogle(input);
  }

  async mountGoogleControl(input: {
    element: HTMLElement;
    onError(error: Error): void;
    onResult(result: { kind: "signed_in" } | SessionLoginChallenge): void;
  }) {
    let active = true;
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = messages.auth_continue_google({}, { locale: this.locale });
    button.className = "app-login-primary";
    const onClick = () => {
      if (active) {
        void this.signInWithGoogle(input);
      }
    };
    button.addEventListener("click", onClick);
    input.element.replaceChildren(button);

    return () => {
      active = false;
      button.removeEventListener("click", onClick);
      input.element.replaceChildren();
    };
  }

  private async signInWithGoogle(input: {
    onError(error: Error): void;
    onResult(result: { kind: "signed_in" } | SessionLoginChallenge): void;
  }) {
    const previousAttempt = this.activeAttempt;
    let pending: { expected: SessionAbsenceExpectation } | undefined;
    try {
      pending = {
        expected: this.pendingGoogle?.expected ?? this.currentAbsenceExpectation(),
      };
      this.pendingGoogle = pending;
      const result = await this.bridge.signInWithGoogle({
        expected: pending.expected,
      });
      if (this.pendingGoogle !== pending) return;
      if (!result.ok) {
        await this.synchronizeAttemptAfterFailure(result.error.code, previousAttempt);
        if (this.pendingGoogle !== pending) return;
        input.onError(sessionOperationError(result.error.code, this.locale));
        return;
      }
      if (result.value.status === "signed_in") {
        this.activeAttempt = undefined;
        input.onResult({ kind: "signed_in" });
        return;
      }
      this.activeAttempt = {
        attempt: result.value.attempt,
        purpose: "google_link",
      };
      input.onResult({
        challengeId: result.value.challengeId,
        email: result.value.email,
        kind: "challenge",
        purpose: "google_link",
      });
    } catch (error) {
      if (pending && this.pendingGoogle !== pending) return;
      await this.synchronizeAttemptAfterFailure(undefined, previousAttempt);
      if (pending && this.pendingGoogle !== pending) return;
      input.onError(error instanceof Error ? error : new Error(String(error)));
    } finally {
      if (this.pendingGoogle === pending) this.pendingGoogle = undefined;
    }
  }

  private currentAbsenceExpectation(): SessionAbsenceExpectation {
    const snapshot = this.getSnapshot();
    if (snapshot.phase !== "signed_out") {
      throw new Error(messages.auth_attempt_stale({}, { locale: this.locale }));
    }
    return {
      authorityInstanceId: snapshot.authority.authorityInstanceId,
      expectedSessionId: null,
      generation: snapshot.generation,
    };
  }

  private requireAttempt(purpose: ElectronActiveAttempt["purpose"]) {
    if (!this.activeAttempt || this.activeAttempt.purpose !== purpose) {
      throw new Error(messages.auth_attempt_stale({}, { locale: this.locale }));
    }
    return this.activeAttempt;
  }

  private async synchronizeAttemptAfterFailure(
    code: string | undefined,
    failedAttempt: ElectronActiveAttempt | undefined
  ) {
    if (this.activeAttempt !== failedAttempt) {
      return;
    }
    if (code === "conflict" || code === "cancelled") {
      this.activeAttempt = undefined;
      return;
    }
    try {
      if ((await this.bridge.state.get()).phase !== "authenticating") {
        this.activeAttempt = undefined;
      }
    } catch {
      // Keep the last exact attempt when Main state cannot be read. A later
      // lifecycle projection or explicit cancellation will settle it safely.
    }
  }
}

function recoveryExpectation(
  snapshot: SessionLifecycleSnapshot
): SessionLifecycleExpectation | undefined {
  if (snapshot.phase === "signed_in" || snapshot.phase === "signed_out") {
    return sessionExpectation(snapshot);
  }
  return undefined;
}

function signedInSnapshotIdentity(
  snapshot: SessionLifecycleSnapshot
): string | undefined {
  return snapshot.phase === "signed_in"
    ? productExpectationIdentity(signedInExpectation(snapshot))
    : undefined;
}

function signedInExpectation(
  snapshot: SignedInSessionSnapshot
): SessionPresenceExpectation {
  return {
    authorityInstanceId: snapshot.authority.authorityInstanceId,
    expectedAudience: snapshot.session.audience,
    expectedSessionId: snapshot.session.sessionId,
    generation: snapshot.generation,
  };
}

function productExpectationIdentity(expectation: SessionPresenceExpectation) {
  return JSON.stringify([
    expectation.authorityInstanceId,
    expectation.generation,
    expectation.expectedSessionId,
    expectation.expectedAudience,
  ]);
}

function uninitializedElectronSnapshot(): SessionLifecycleSnapshot {
  return {
    authority: {
      authorityInstanceId: "electron-renderer-uninitialized",
      kind: "electron_main",
    },
    cleanup: { revocation: "unknown" },
    contractVersion: 1,
    generation: 0,
    phase: "indeterminate",
    principal: null,
    problem: createSessionProblem("protocol_mismatch", "initialize"),
    revision: 0,
    session: null,
  };
}

function sessionOperationError(code: string, locale: CommaLocale) {
  return sessionOperationDisplayError(
    code,
    messages.auth_desktop_unsupported({}, { locale }),
    locale
  );
}

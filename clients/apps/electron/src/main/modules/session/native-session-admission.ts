import { AsyncLocalStorage } from "node:async_hooks";
import {
  sameSessionProductLease,
  sessionProductLease,
  sessionProductLeaseSchema,
  type SessionProductLease,
} from "@comma/session-contract";
import type { NativeCommandContract } from "@comma/native-bridge";
import { NativeSessionAdmissionError } from "../ipc";
import {
  MainCredentialGate,
  type MainProductCredentialLease,
} from "./main-credential-gate";

export interface NativeSessionAdmissionContext {
  credential: MainProductCredentialLease;
  principalUserId: string;
  session: SessionProductLease;
}

const nativeSessionAdmissionStorage =
  new AsyncLocalStorage<NativeSessionAdmissionContext>();

export class MainNativeSessionAdmissionGuard {
  readonly #authority: MainCredentialGate;

  constructor(authority: MainCredentialGate) {
    this.#authority = authority;
  }

  /** Admit a Main-owned background command using the same current-session fence. */
  runOwned<Output>(handler: () => Promise<Output> | Output): Promise<Output> | Output {
    const session = sessionProductLease(this.#authority.getSnapshot());
    if (!session) throw this.#admissionError();
    return this.#runSession(session, handler);
  }

  /**
   * Admit a command the client core gives Main for its lease (the meeting recorder's): refused unless that lease is
   * Main's current one. `assertCurrent` throws once the lease's credential is no longer current.
   */
  runLease<Output>(
    session: SessionProductLease,
    handler: (assertCurrent: () => void) => Promise<Output> | Output
  ): Promise<Output> {
    return this.#runSession(session, () => {
      const { credential } = getCurrentNativeSessionAdmission();
      return handler(() => {
        if (!this.#authority.isCurrentProductCredential(credential))
          throw this.#admissionError();
      });
    });
  }

  run<Input, Output>({
    contract,
    handler,
    input,
  }: {
    contract: NativeCommandContract<Input, Output>;
    handler: () => Promise<Output> | Output;
    input: Input;
  }): Promise<Output> | Output {
    if (contract.sessionAdmission !== "required") return handler();

    const session = sessionProductLeaseSchema.safeParse(
      isRecord(input) ? input.session : undefined
    );
    if (!session.success) throw this.#admissionError();

    return this.#runSession(session.data, handler);
  }

  #runSession<Output>(
    session: SessionProductLease,
    handler: () => Promise<Output> | Output
  ): Promise<Output> {
    const snapshot = this.#authority.getSnapshot();
    const currentSession = sessionProductLease(snapshot);
    if (
      snapshot.phase !== "signed_in" ||
      !currentSession ||
      !sameSessionProductLease(currentSession, session)
    ) {
      throw this.#admissionError();
    }

    const credential = this.#authority.acquireProductCredential({
      authorityInstanceId: session.authorityInstanceId,
      expectedAudience: session.audience,
      expectedSessionId: session.sessionId,
      generation: session.generation,
    });
    if (!credential) throw this.#admissionError();

    return nativeSessionAdmissionStorage.run(
      {
        credential,
        principalUserId: snapshot.principal.userId,
        session: session,
      },
      async () => {
        const output = await handler();
        if (!this.#authority.isCurrentProductCredential(credential)) {
          throw this.#admissionError();
        }
        return output;
      }
    );
  }

  #admissionError() {
    return new NativeSessionAdmissionError(this.#authority.admissionFailure());
  }
}

export function getCurrentNativeSessionAdmission(): NativeSessionAdmissionContext {
  const admission = nativeSessionAdmissionStorage.getStore();
  if (!admission) {
    throw new Error("No native Session admission context is active.");
  }
  return admission;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

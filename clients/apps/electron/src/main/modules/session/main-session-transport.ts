import type { SessionProductLease } from "@comma/session-contract";
import { NativeSessionAdmissionError } from "../ipc";
import { getCurrentNativeSessionAdmission } from "./native-session-admission";
import type {
  MainProductCredentialLease,
  MainCredentialGate,
} from "./main-credential-gate";

export interface MainSessionTransportAuthority {
  readonly authority: MainCredentialGate;
  reportUnauthorized(lease: MainProductCredentialLease): Promise<void>;
}

export interface MainSessionBoundApi {
  readonly session: SessionProductLease;
  assertCurrent(): void;
  isCurrent(): boolean;
}

export function createCurrentMainSessionApiBinding({
  session,
}: {
  session: MainSessionTransportAuthority;
}): MainSessionBoundApi {
  const admission = getCurrentNativeSessionAdmission();
  settleCredential(session, admission.credential);
  const assertCurrent = () => settleCredential(session, admission.credential);
  return {
    assertCurrent,
    isCurrent: () => session.authority.isCurrentProductCredential(admission.credential),
    session: admission.session,
  };
}

function settleCredential(
  session: MainSessionTransportAuthority,
  credential: MainProductCredentialLease
) {
  if (!session.authority.isCurrentProductCredential(credential)) {
    throw new NativeSessionAdmissionError(session.authority.admissionFailure());
  }
}

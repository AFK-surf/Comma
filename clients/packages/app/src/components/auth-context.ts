import { createContext, useContext } from "react";
import type { SessionProductLease } from "@comma/session-contract";
import type { CommaApiSessionTransport } from "../session/controller";

export type CommaAuthContextValue = {
  apiBaseUrl: string;
  avatarRevision?: string;
  authenticated: boolean;
  /**
   * Present only for a guest Session: ends it so the next sign-in imports
   * the guest chat. Rejects with a displayable error.
   */
  beginGuestSignUp?: () => Promise<void>;
  /**
   * A guest Session has only its Router chat. Its placeholder email is never
   * shown; `userDisplayName` carries the localized guest name.
   */
  isGuest?: boolean;
  productLease: SessionProductLease;
  sessionSignal: AbortSignal;
  sessionTransport: CommaApiSessionTransport;
  signOut: () => void;
  /**
   * The accounts signed in on this device besides this one, and what can be done with them (hosts that keep the
   * bearer: Electron). Absent where a device keeps one account.
   */
  otherAccounts?: {
    list: readonly { userId: string; email: string }[];
    /** Sets this account aside, still signed in, and shows the sign-in for another. */
    add(): Promise<void>;
    switchTo(userId: string): Promise<void>;
    signOut(userId: string): Promise<void>;
  };
  userId?: string;
  userDisplayName?: string;
  userEmail: string;
};

export const CommaAuthContext = createContext<CommaAuthContextValue | undefined>(
  undefined
);

export function useCommaAuth() {
  const value = useContext(CommaAuthContext);
  if (!value) {
    throw new Error("useCommaAuth must be used inside CommaAuthGate.");
  }
  return value;
}

/** True inside a guest Session; false outside CommaAuthGate. */
export function useIsGuestSession() {
  return useContext(CommaAuthContext)?.isGuest === true;
}

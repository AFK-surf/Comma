import { createContext, useContext } from "react";
import type { SessionProductLease } from "@comma/session-contract";
import type {
  CommaApiClient,
  CommaApiSessionTransport,
  CommaUserProfile,
} from "../api";

export type CommaAuthContextValue = {
  /**
   * The API client for this product lease, built once from its transport. A
   * new lease (a sign-in, an account switch, or a reconcile that bumps the
   * generation) replaces it. Product surfaces reach it through the chat
   * session, which fences each call to the current lease generation.
   */
  api: CommaApiClient;
  apiBaseUrl: string;
  avatarRevision?: string;
  authenticated: boolean;
  productLease: SessionProductLease;
  sessionSignal: AbortSignal;
  sessionTransport: CommaApiSessionTransport;
  publishProfile?: (profile: CommaUserProfile) => void;
  signOut: () => void;
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

// The signed-in session as Admin requests see it. Every product request is made for one lease: it carries the lease's
// session id (`x-comma-expected-auth-session-id`), so the server refuses it with 409 when the Cookie names another
// session, and it is stopped when the lease ends. A refusal for the session goes back to the auth service (auth.ts).
import { Context, Deferred, type Effect } from "effect";

export interface SessionLease {
  /** Completes when the lease ends: signed out, refused by the server, or replaced by another session. */
  readonly closed: Deferred.Deferred<void>;
  readonly email: string;
  readonly sessionId: string;
  readonly userId: string;
}

export class AdminSession extends Context.Service<
  AdminSession,
  {
    /** The lease product requests are made for now, if a session is signed in. */
    readonly lease: Effect.Effect<SessionLease | undefined>;
    /** The server refused a request made for `lease`: 401 (no session), or 409 (another session holds the Cookie). */
    readonly refused: (lease: SessionLease, status: 401 | 409) => Effect.Effect<void>;
  }
>()("admin/AdminSession") {}

/** The headers of a product request made for `lease` with the Cookie transport. */
export function sessionHeaders(sessionId: string): Record<string, string> {
  return {
    "x-comma-expected-auth-session-id": sessionId,
    "x-comma-session-lifecycle-version": "1",
    "x-comma-session-transport": "cookie",
  };
}

export const leaseIsOpen = (lease: SessionLease) =>
  !Deferred.isDoneUnsafe(lease.closed);

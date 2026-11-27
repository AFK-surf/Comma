// Connecting the extension to a Comma account.
//
// The extension starts it: it keeps a random verifier and sends the desktop app only the verifier's SHA-256. The
// person confirms in Comma, which hands back a one-time pairing in a `raycast://` link. Any app can open such a link,
// so a pairing counts only while this extension waits for one, and the server issues a session only for the verifier
// whose challenge the pairing carries. A link this extension did not ask for is dropped.
import { createHash, randomBytes } from "node:crypto";
import type { CommaApi } from "./api";
import { connectLink } from "./links";
import type { CommaStore, Session } from "./store";

/** How long a started connection waits for the person to confirm in Comma. */
export const CONNECT_WAIT_MS = 10 * 60_000;

export type ConnectFailure = "not_started" | "malformed" | "refused";

export class ConnectError extends Error {
  readonly reason: ConnectFailure;
  constructor(reason: ConnectFailure) {
    super(`Comma connection failed: ${reason}`);
    this.reason = reason;
  }
}

const base64url = (bytes: Buffer) => bytes.toString("base64url");

export function challengeOf(verifier: string): string {
  return base64url(createHash("sha256").update(verifier).digest());
}

/** Starts a connection: remembers a new verifier and opens Comma to ask the person. */
export async function beginConnect(deps: {
  store: CommaStore;
  scheme: string;
  now(): number;
  open(url: string): Promise<void>;
  random?(): Buffer;
}): Promise<void> {
  const verifier = base64url((deps.random ?? (() => randomBytes(32)))());
  await deps.store.setPending({ verifier, startedAt: deps.now() });
  await deps.open(connectLink(deps.scheme, challengeOf(verifier)));
}

/** Finishes the connection a `raycast://` link carries (`context`), if this extension is waiting for one. */
export async function finishConnect(
  context: unknown,
  deps: {
    store: CommaStore;
    api: CommaApi;
    now(): number;
    platform: "macos" | "windows";
  }
): Promise<Session> {
  const pairing = context as { pairingId?: unknown; pairingSecret?: unknown } | null;
  if (
    !pairing ||
    typeof pairing.pairingId !== "string" ||
    typeof pairing.pairingSecret !== "string"
  )
    throw new ConnectError("malformed");
  const pending = await deps.store.pending();
  if (!pending || deps.now() - pending.startedAt > CONNECT_WAIT_MS)
    throw new ConnectError("not_started");
  // One link per started connection: a second link, forged or repeated, finds nothing waiting.
  await deps.store.clearPending();
  let issued;
  try {
    issued = await deps.api.exchange({
      pairingId: pairing.pairingId,
      pairingSecret: pairing.pairingSecret,
      verifier: pending.verifier,
      platform: deps.platform,
    });
  } catch {
    throw new ConnectError("refused");
  }
  const session = {
    token: issued.token,
    email: issued.email,
    expiresAt: issued.expiresAt,
  };
  // The new session can be another account's: nothing chosen for the session before it carries over.
  await deps.store.clearSession();
  await deps.store.setSession(session);
  return session;
}

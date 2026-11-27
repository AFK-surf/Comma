/**
 * Connects the Raycast extension that asked to be (`<scheme>://connect/raycast?challenge=…`, launcher-link.ts).
 *
 * Any app can open that link, so nothing is granted until the person confirms here, in a dialog of Main's own that
 * names the account. Main's session then asks for a one-time pairing bound to the extension's challenge and hands it
 * to Raycast in a link. Only the extension that kept the challenge's verifier can exchange it for a session, so a
 * pairing another app reads is of no use to it. This session's credential never leaves Main.
 */

/**
 * The published extension, as `<owner or author handle>/<name>` in a Raycast deeplink. It must equal the `owner`
 * (else `author`) and `name` of the extension's manifest (clients/apps/raycast/package.json).
 */
export const RAYCAST_EXTENSION = "afk-inc/comma";

export interface RaycastPairing {
  pairingId: string;
  pairingSecret: string;
  expiresAt: number;
}

export interface RaycastConnectDeps {
  /** The signed-in registered account's email; undefined for a guest or when nobody is signed in. */
  account(): string | undefined;
  /** Asks the person, naming `account`; true only when they chose to connect. */
  confirm(account: string): Promise<boolean>;
  /** `accountSessions.pairRaycast` of the client core. */
  pair(challenge: string): Promise<RaycastPairing>;
  /** Opens a link in its application. */
  open(url: string): Promise<void>;
  /** Tells the person to sign in first: nobody, or a guest, is signed in, or the account changed while they decided. */
  signedOut?: () => void;
  /** Tells the person the connection did not happen, and records why. */
  failed(error: unknown): void;
}

export type RaycastConnectOutcome =
  | "connected"
  | "declined"
  | "signed_out"
  | "busy"
  | "failed";

/** The link that hands `pairing` to the extension's Connect command (its `launchContext`). */
export function raycastConnectLink(pairing: RaycastPairing): string {
  const context = encodeURIComponent(
    JSON.stringify({
      pairingId: pairing.pairingId,
      pairingSecret: pairing.pairingSecret,
    })
  );
  return `raycast://extensions/${RAYCAST_EXTENSION}/connect?context=${context}`;
}

export class RaycastConnector {
  readonly #deps: RaycastConnectDeps;
  #asking = false;

  constructor(deps: RaycastConnectDeps) {
    this.#deps = deps;
  }

  /** One request at a time: links that arrive while the person is deciding ask nothing more. */
  async connect(challenge: string): Promise<RaycastConnectOutcome> {
    if (this.#asking) return "busy";
    const account = this.#deps.account();
    if (!account) return this.#signedOut();
    this.#asking = true;
    try {
      if (!(await this.#deps.confirm(account))) return "declined";
      // The person may have signed out or switched account while the dialog was open.
      if (this.#deps.account() !== account) return this.#signedOut();
      await this.#deps.open(raycastConnectLink(await this.#deps.pair(challenge)));
      return "connected";
    } catch (error) {
      this.#deps.failed(error);
      return "failed";
    } finally {
      this.#asking = false;
    }
  }

  #signedOut(): "signed_out" {
    this.#deps.signedOut?.();
    return "signed_out";
  }
}

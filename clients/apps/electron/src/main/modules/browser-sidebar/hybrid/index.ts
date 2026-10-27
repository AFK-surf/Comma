import { realMainClock, type MainClock } from "../../../clock";
import { createCableQrSession, decryptCableAdvert, type CableAdvert } from "./cable";
import { CableTransportError, runCableTransaction } from "./tunnel";
import {
  WebAuthnError,
  clientDataJson,
  ctapCommand,
  pageCredential,
  relyingPartyId,
  type PageCredential,
  type PageCredentialRequest,
} from "./webauthn";

export type { PageCredential, PageCredentialRequest } from "./webauthn";
export { WebAuthnError, pageCredentialRequestSchema } from "./webauthn";

/**
 * `on`: scanning. `off`: Bluetooth is switched off. `denied`: the user did not
 * allow Comma to use Bluetooth. `unsupported`: this Mac has no Bluetooth LE.
 * `pending`: not known yet, for example while macOS asks the user.
 */
export type BluetoothState = "on" | "off" | "denied" | "unsupported" | "pending";

export interface CableScanListener {
  /** A 20-byte caBLE service-data advert. Other phones' adverts arrive too. */
  advert(data: Uint8Array): void;
  state(state: BluetoothState): void;
}

/** Nearby caBLE adverts, from CoreBluetooth or a test. */
export interface CableScanner {
  /** Reports adverts and Bluetooth changes until `signal` aborts. */
  scan(listener: CableScanListener, signal: AbortSignal): void;
}

export type HybridPasskeyState =
  | { phase: "scan"; qr: string; bluetooth: BluetoothState }
  | { phase: "connecting" }
  | { phase: "phone" };

/**
 * Runs one passkey request through a phone: shows a QR code, waits for the
 * phone's advert, and completes the request over the tunnel. Each request
 * gets a new QR code; a failure after the phone connected ends the request,
 * as in Chromium.
 */
export class HybridPasskeys {
  readonly #clock: MainClock;
  readonly #scanner: CableScanner;
  readonly #tunnelOrigin: string | undefined;
  /** Steps and failures of each request, without keys or QR contents. */
  readonly logger: Pick<Console, "info" | "warn"> | undefined;

  constructor({
    clock = realMainClock,
    logger,
    scanner,
    tunnelOrigin,
  }: {
    clock?: MainClock | undefined;
    logger?: Pick<Console, "info" | "warn"> | undefined;
    scanner: CableScanner;
    /** Replaces the tunnel server origin for tests. */
    tunnelOrigin?: string | undefined;
  }) {
    this.#clock = clock;
    this.logger = logger;
    this.#scanner = scanner;
    this.#tunnelOrigin = tunnelOrigin;
  }

  async run({
    origin,
    request,
    signal,
    onState,
  }: {
    origin: string;
    request: PageCredentialRequest;
    signal: AbortSignal;
    onState: (state: HybridPasskeyState) => void;
  }): Promise<PageCredential> {
    const rpId = relyingPartyId(
      origin,
      request.kind === "create" ? request.options.rp.id : request.options.rpId
    );
    const clientData = clientDataJson(
      request.kind === "create" ? "webauthn.create" : "webauthn.get",
      request.options.challenge,
      new URL(origin).origin
    );
    const session = createCableQrSession(request.kind === "create" ? "mc" : "ga", {
      clock: this.#clock,
    });
    let bluetooth: BluetoothState = "pending";
    this.logger?.info(
      `[browser-passkeys] ${request.kind} for ${rpId}: showing the QR code`
    );
    onState({ phase: "scan", qr: session.uri, bluetooth });
    const advert = await this.#findPhone(session.eidKey, signal, (state) => {
      if (state === bluetooth) return;
      bluetooth = state;
      this.logger?.info(`[browser-passkeys] Bluetooth is ${state}`);
      onState({ phase: "scan", qr: session.uri, bluetooth });
    });

    this.logger?.info(`[browser-passkeys] found the phone; tunnel ${advert.domain}`);
    onState({ phase: "connecting" });
    let built: ReturnType<typeof ctapCommand> | undefined;
    let getInfo = new Map<number, unknown>();
    let connected = false;
    let reply;
    try {
      reply = await runCableTransaction({
        clock: this.#clock,
        session,
        advert,
        signal,
        tunnelOrigin: this.#tunnelOrigin,
        onConnected: () => {
          connected = true;
          this.logger?.info("[browser-passkeys] connected; waiting for the phone");
          onState({ phase: "phone" });
        },
        command: (info) => {
          getInfo = info;
          built = ctapCommand(request, rpId, clientData, info);
          return built.command;
        },
      });
    } catch (error) {
      if (error instanceof CableTransportError) {
        this.logger?.warn(`[browser-passkeys] tunnel failed: ${error.message}`);
        // The user already saw the outcome on the phone, such as a cancel.
        if (connected && error.phoneClosed) {
          throw new WebAuthnError("NotAllowedError", "The phone ended the request.");
        }
        throw new WebAuthnError("NotAllowedError", error.message, "connection");
      }
      throw error;
    }
    this.logger?.info(
      `[browser-passkeys] the phone answered with status ${reply.status}`
    );
    return pageCredential({
      request,
      rpId,
      clientData,
      status: reply.status,
      body: reply.body,
      rk: built?.rk ?? false,
      getInfo,
    });
  }

  /** Scans until an advert decrypts under this request's key. */
  #findPhone(
    eidKey: Buffer,
    signal: AbortSignal,
    onBluetooth: (state: BluetoothState) => void
  ) {
    return new Promise<CableAdvert>((resolve, reject) => {
      const scan = new AbortController();
      let otherAdvertSeen = false;
      const stop = () => {
        scan.abort();
        signal.removeEventListener("abort", onAbort);
      };
      const onAbort = () => {
        stop();
        reject(signal.reason ?? new DOMException("Aborted", "AbortError"));
      };
      if (signal.aborted) {
        onAbort();
        return;
      }
      signal.addEventListener("abort", onAbort, { once: true });
      try {
        this.#scanner.scan(
          {
            advert: (data) => {
              if (scan.signal.aborted) return;
              const advert = decryptCableAdvert(data, eidKey);
              if (!advert) {
                // Other phones advertise too; one line shows that scanning works.
                if (!otherAdvertSeen) {
                  otherAdvertSeen = true;
                  this.logger?.info(
                    "[browser-passkeys] saw a caBLE advert of another QR code"
                  );
                }
                return;
              }
              stop();
              resolve(advert);
            },
            state: (state) => {
              if (!scan.signal.aborted) onBluetooth(state);
            },
          },
          scan.signal
        );
      } catch (error) {
        stop();
        reject(error);
      }
    });
  }
}

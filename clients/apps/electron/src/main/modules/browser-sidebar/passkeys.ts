import type { BrowserSidebarPasskeyPrompt } from "@comma/native-bridge";
import { z } from "zod";
import {
  WebAuthnError,
  pageCredentialRequestSchema,
  type HybridPasskeyState,
  type HybridPasskeys,
  type PageCredential,
} from "./hybrid";
import { relyingPartyId } from "./hybrid/webauthn";

/** How long a QR code waits for a phone, whatever the page asks for. */
const maxPromptMs = 10 * 60_000;

// What the page broker of `preload/browser-page-webauthn.ts` sends.
const brokerEventSchema = z.discriminatedUnion("type", [
  z.object({
    type: z.literal("request"),
    document: z.string().min(1).max(64),
    origin: z.string().max(2048),
    id: z.number().int().positive(),
    request: z.unknown(),
    securityKey: z.boolean(),
  }),
  z.object({
    type: z.literal("cancel"),
    document: z.string().min(1).max(64),
    id: z.number().int().positive(),
  }),
  z.object({ type: z.literal("replaced") }),
]);
type BrokerRequest = Extract<z.infer<typeof brokerEventSchema>, { type: "request" }>;

type Outcome =
  | { credential: PageCredential }
  | { error: { message: string; name: string } };

const failure = (name: string, message: string): Outcome => ({
  error: { message, name },
});

/** The top frame of a browser tab, as the passkey broker uses it. */
export interface BrowserPasskeyPage {
  /** The serialized origin of the current top-level document. */
  origin(): string | undefined;
  /** Runs `source` in the main world of the top frame. */
  execute(source: string): Promise<unknown>;
  isDestroyed(): boolean;
}

/**
 * Answers the passkey requests of one browser tab with a phone. Main polls
 * the page's broker, checks the relying party against the frame's own origin,
 * shows the QR code through the tab state, and returns the result to the
 * document that asked. One request runs at a time, as in Chromium.
 */
export class BrowserTabPasskeys {
  readonly #page: BrowserPasskeyPage;
  readonly #phone: HybridPasskeys;
  readonly #canPrompt: () => boolean;
  readonly #onPromptChanged: () => void;
  #generation = 0;
  #polling = false;
  #current: { abort: AbortController; document: string; id: number } | undefined;
  #prompt: BrowserSidebarPasskeyPrompt | undefined;
  #disposed = false;

  constructor({
    page,
    phone,
    canPrompt,
    onPromptChanged,
  }: {
    page: BrowserPasskeyPage;
    phone: HybridPasskeys;
    /** False while the tab is hidden or closing: its page gets no dialog. */
    canPrompt: () => boolean;
    onPromptChanged: () => void;
  }) {
    this.#page = page;
    this.#phone = phone;
    this.#canPrompt = canPrompt;
    this.#onPromptChanged = onPromptChanged;
  }

  get prompt() {
    return this.#prompt;
  }

  /** A new top-level document committed: requests of the old one end. */
  documentChanged() {
    if (this.#disposed) return;
    this.#current?.abort.abort(
      new WebAuthnError("NotAllowedError", "The page changed.")
    );
    this.#setPrompt(undefined);
    this.#startPolling();
  }

  /** The document finished parsing; poll if the broker was not ready before. */
  documentReady() {
    if (!this.#disposed && !this.#polling) this.#startPolling();
  }

  /** The user closed the dialog: the request ends as a browser ends it. */
  dismiss() {
    if (this.#current) {
      this.#current.abort.abort(
        new WebAuthnError("NotAllowedError", "The user cancelled the request.")
      );
    } else {
      this.#setPrompt(undefined);
    }
  }

  dispose() {
    this.#disposed = true;
    this.#generation += 1;
    this.#current?.abort.abort(new WebAuthnError("NotAllowedError", "The tab closed."));
    this.#prompt = undefined;
  }

  #setPrompt(prompt: BrowserSidebarPasskeyPrompt | undefined) {
    if (prompt === undefined && this.#prompt === undefined) return;
    this.#prompt = prompt;
    if (!this.#disposed) this.#onPromptChanged();
  }

  #startPolling() {
    const generation = ++this.#generation;
    this.#polling = true;
    void this.#poll(generation).finally(() => {
      if (generation === this.#generation) this.#polling = false;
    });
  }

  async #poll(generation: number) {
    while (generation === this.#generation && !this.#page.isDestroyed()) {
      let raw: unknown;
      try {
        raw = await this.#page.execute("globalThis.__commaPasskeys?.next()");
      } catch {
        return;
      }
      if (generation !== this.#generation) return;
      // No broker yet, or a newer poll took over.
      const event = brokerEventSchema.safeParse(raw);
      if (!event.success || event.data.type === "replaced") return;
      if (event.data.type === "cancel") {
        const current = this.#current;
        if (current?.document === event.data.document && current.id === event.data.id) {
          current.abort.abort(
            new WebAuthnError("NotAllowedError", "The page cancelled the request.")
          );
        }
        continue;
      }
      void this.#answer(event.data, generation);
    }
  }

  async #answer(event: BrokerRequest, generation: number) {
    const settle = (outcome: Outcome) => this.#settle(event, outcome, generation);
    if (this.#current) {
      await settle(failure("NotAllowedError", "A request is already pending."));
      return;
    }
    const origin = this.#page.origin();
    const parsed = pageCredentialRequestSchema.safeParse(event.request);
    // The document that asked is no longer the one in the tab.
    if (!origin || origin !== event.origin || !parsed.success || !this.#canPrompt()) {
      this.#phone.logger?.warn(
        `[browser-passkeys] refused a request: ${
          !parsed.success
            ? "invalid options"
            : origin !== event.origin
              ? "the page changed"
              : "the tab is in the background"
        }`
      );
      await settle(failure("NotAllowedError", "The request was not allowed."));
      return;
    }
    const request = parsed.data;
    let site: string;
    try {
      site = relyingPartyId(
        origin,
        request.kind === "create" ? request.options.rp.id : request.options.rpId
      );
    } catch (error) {
      const name = error instanceof WebAuthnError ? error.domName : "SecurityError";
      await settle(failure(name, "The relying party id is invalid for this page."));
      return;
    }

    const abort = new AbortController();
    const current = { abort, document: event.document, id: event.id };
    this.#current = current;
    const prompt = (state: HybridPasskeyState): BrowserSidebarPasskeyPrompt => ({
      site,
      kind: request.kind,
      securityKey: event.securityKey,
      ...(state.phase === "scan"
        ? { phase: "scan", qr: state.qr, bluetooth: state.bluetooth }
        : { phase: state.phase }),
    });
    let outcome: Outcome;
    let failed = false;
    try {
      const credential = await this.#phone.run({
        origin,
        request,
        signal: AbortSignal.any([abort.signal, AbortSignal.timeout(maxPromptMs)]),
        onState: (state) => {
          if (this.#current === current) this.#setPrompt(prompt(state));
        },
      });
      outcome = { credential };
    } catch (error) {
      this.#phone.logger?.info(
        `[browser-passkeys] the request ended: ${error instanceof Error ? error.message : String(error)}`
      );
      if (error instanceof WebAuthnError) {
        outcome = failure(error.domName, error.message);
        failed = error.reason === "connection" && !abort.signal.aborted;
      } else {
        // A timeout, or a cancellation from the page, the user or Main.
        outcome = failure(
          "NotAllowedError",
          "The operation either timed out or was not allowed."
        );
      }
    } finally {
      if (this.#current === current) this.#current = undefined;
    }
    if (generation === this.#generation) {
      this.#setPrompt(
        failed
          ? {
              site,
              kind: request.kind,
              phase: "failed",
              securityKey: event.securityKey,
            }
          : undefined
      );
    }
    await settle(outcome);
  }

  async #settle(event: BrokerRequest, outcome: Outcome, generation: number) {
    // The page's broker accepts the outcome only in the document that asked.
    if (generation !== this.#generation || this.#page.isDestroyed()) return;
    await this.#page
      .execute(
        `globalThis.__commaPasskeys?.settle(${JSON.stringify(event.document)}, ${
          event.id
        }, ${JSON.stringify(outcome)})`
      )
      .catch(() => undefined);
  }
}

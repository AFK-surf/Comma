import { type ProductInboxListInput } from "@comma/native-bridge";
import {
  sameSessionProductLease,
  type SessionProductLease,
} from "@comma/session-contract";
import {
  productInboxDemandInputSchema,
  productInboxRefreshInputSchema,
  type ProductInboxDemandInput,
  type ProductInboxStateEnvelope,
} from "./contracts";
import { ProductInboxRuntime } from "./runtime";

export type ProductInboxSubscriberKey = number | string;

export interface ProductInboxNativeDemandProviderOptions<
  SubscriberKey extends ProductInboxSubscriberKey,
> {
  publish(subscriberKey: SubscriberKey, envelope: ProductInboxStateEnvelope): void;
  runtime: ProductInboxRuntime;
}

interface ProductInboxDemandRegistration {
  session: SessionProductLease;
  unsubscribe(): void;
}

/**
 * Caller-bound facade for generated native demand wiring.
 *
 * Composition supplies the caller key and publication function. This facade
 * does not inspect WebContents, IPC events, or the event bus, and one caller
 * key owns at most one runtime retention.
 */
export class ProductInboxNativeDemandProvider<
  SubscriberKey extends ProductInboxSubscriberKey = ProductInboxSubscriberKey,
> {
  readonly #publish: (
    subscriberKey: SubscriberKey,
    envelope: ProductInboxStateEnvelope
  ) => void;
  readonly #registrations = new Map<SubscriberKey, ProductInboxDemandRegistration>();
  readonly #runtime: ProductInboxRuntime;

  constructor({
    publish,
    runtime,
  }: ProductInboxNativeDemandProviderOptions<SubscriberKey>) {
    this.#publish = publish;
    this.#runtime = runtime;
  }

  close(): void {
    for (const [subscriberKey, registration] of this.#registrations) {
      this.#releaseRegistration(subscriberKey, registration);
    }
  }

  state(inputValue: ProductInboxDemandInput): ProductInboxStateEnvelope {
    const input = productInboxDemandInputSchema.parse(inputValue);
    const envelope = this.#runtime.get(input.session);
    this.#releaseRegistrationsOutside(input.session);
    return envelope;
  }

  retain(
    inputValue: ProductInboxDemandInput,
    subscriberKey: SubscriberKey
  ): ProductInboxStateEnvelope {
    const input = productInboxDemandInputSchema.parse(inputValue);
    const initial = this.#runtime.get(input.session);
    this.#releaseRegistrationsOutside(input.session);
    const existing = this.#registrations.get(subscriberKey);
    if (existing && sameSessionProductLease(existing.session, input.session)) {
      return initial;
    }
    if (existing) this.#releaseRegistration(subscriberKey, existing);

    this.#runtime.retain(input.session);
    let unsubscribe: () => void;
    try {
      unsubscribe = this.#runtime.subscribe(input.session, (envelope) => {
        this.#publish(subscriberKey, envelope);
      });
    } catch (error) {
      this.#runtime.release(input.session);
      throw error;
    }
    this.#registrations.set(subscriberKey, {
      session: input.session,
      unsubscribe,
    });
    return initial;
  }

  release(inputValue: ProductInboxDemandInput, subscriberKey: SubscriberKey): boolean {
    const input = productInboxDemandInputSchema.parse(inputValue);
    const existing = this.#registrations.get(subscriberKey);
    if (!existing || !sameSessionProductLease(existing.session, input.session)) {
      return false;
    }
    this.#releaseRegistration(subscriberKey, existing);
    return true;
  }

  releaseAll(subscriberKey: SubscriberKey): void {
    const existing = this.#registrations.get(subscriberKey);
    if (existing) this.#releaseRegistration(subscriberKey, existing);
  }

  async refresh(inputValue: ProductInboxListInput): Promise<ProductInboxStateEnvelope> {
    const input = productInboxRefreshInputSchema.parse(inputValue);
    const settled = await this.#runtime.refresh(input);
    this.#releaseRegistrationsOutside(input.session);
    return settled;
  }

  #releaseRegistration(
    subscriberKey: SubscriberKey,
    registration: ProductInboxDemandRegistration
  ): void {
    this.#registrations.delete(subscriberKey);
    registration.unsubscribe();
    this.#runtime.release(registration.session);
  }

  #releaseRegistrationsOutside(session: SessionProductLease): void {
    for (const [subscriberKey, registration] of this.#registrations) {
      if (sameSessionProductLease(registration.session, session)) continue;
      this.#releaseRegistration(subscriberKey, registration);
    }
  }
}

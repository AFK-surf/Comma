import {
  chatSurfaceProjectionLimit,
  type ChatCommandReceipt,
  type ChatLeasedTarget,
  type ChatReleaseInput,
  type ChatRetainInput,
} from "@comma/chat-contract";
import type { ChatEntries } from "./entries/ChatEntries";
import { chatKey, type SurfaceProjectionState } from "./entries/chatEntry";
import type { ChatPublisher } from "./entries/ChatPublisher";
import { isSameLiveBoundary } from "./entries/sessionBoundary";
import type { ChatCoordinatorOptions } from "./hostContract";

const DEFAULT_RELEASE_DELAY_MS = 30_000;

/**
 * Each surface's hold on an entry: the lease that keeps it retained until a
 * delay after the last release, and the surface's presentation projection.
 */
export class SurfaceLeases {
  readonly #entries: ChatEntries;
  readonly #publisher: ChatPublisher;
  readonly #releaseDelayMs: number;
  #surfaceProjectionUseSequence = 0;

  constructor(
    entries: ChatEntries,
    {
      releaseDelayMs = DEFAULT_RELEASE_DELAY_MS,
    }: Pick<ChatCoordinatorOptions, "releaseDelayMs">
  ) {
    this.#entries = entries;
    this.#publisher = entries.publisher;
    this.#releaseDelayMs = releaseDelayMs;
  }

  retain(input: ChatRetainInput): ChatCommandReceipt {
    const entry = this.#entries.ensure(input);
    entry.boundary.assertCurrent();
    if (entry.releaseTimer) {
      clearTimeout(entry.releaseTimer);
      entry.releaseTimer = undefined;
    }
    entry.subscribers.set(input.subscriberId, input.leaseId);

    const surfaceProjection = entry.surfaceProjections.get(input.subscriberId);
    if (surfaceProjection) {
      surfaceProjection.lastUsed = ++this.#surfaceProjectionUseSequence;
    }
    entry.channel.start();
    this.#entries.touch(entry);
    entry.boundary.assertCurrent();
    // The retain receipt carries the entry's draft epoch: every admitted
    // sender observes an epoch before it can possibly send, which is what
    // lets the send fence be unconditional.
    return this.#publisher.receipt(entry);
  }

  release(input: ChatReleaseInput): ChatCommandReceipt {
    const boundary = this.#entries.openBoundary();
    boundary.assertCurrent();
    const key = chatKey(input);
    const entry = this.#entries.get(key);
    if (!entry) {
      boundary.assertCurrent();
      return this.#publisher.receipt();
    }

    if (!isSameLiveBoundary(entry.boundary, boundary)) {
      this.#entries.quarantine(key, entry);
      boundary.assertCurrent();
      return this.#publisher.receipt();
    }
    if (entry.subscribers.get(input.subscriberId) !== input.leaseId) {
      entry.boundary.assertCurrent();
      return this.#publisher.receipt();
    }

    entry.subscribers.delete(input.subscriberId);
    const sendIntent = entry.activeSendIntent;
    if (
      sendIntent?.leaseId === input.leaseId &&
      sendIntent.subscriberId === input.subscriberId
    ) {
      entry.activeSendIntent = undefined;
    }
    this.#entries.touch(entry);
    if (entry.subscribers.size === 0 && !entry.releaseTimer) {
      entry.releaseTimer = setTimeout(() => {
        const current = this.#entries.get(key);
        if (!current || current.subscribers.size > 0) {
          return;
        }
        if (!current.boundary.isCurrent()) {
          this.#entries.quarantine(key, current);
          return;
        }
        this.#entries.dispose(key, current);
        this.#publisher.publish(key);
      }, this.#releaseDelayMs);
    }
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }

  clearPresentation(input: ChatLeasedTarget): ChatCommandReceipt {
    const entry = this.#entries.required(input);
    const current = entry.surfaceProjections.get(input.subscriberId);
    if (!current && entry.surfaceProjections.size >= chatSurfaceProjectionLimit) {
      const oldest = [...entry.surfaceProjections.entries()].reduce<
        [string, SurfaceProjectionState] | undefined
      >((candidate, item) => {
        if (entry.subscribers.has(item[0])) {
          return candidate;
        }
        if (!candidate || item[1].lastUsed < candidate[1].lastUsed) {
          return item;
        }
        return candidate;
      }, undefined);
      if (!oldest) {
        throw new Error(
          `Chat surface projection limit (${chatSurfaceProjectionLimit}) reached.`
        );
      }
      entry.surfaceProjections.delete(oldest[0]);
    }

    const observation = entry.channel.getObservationState();
    entry.surfaceProjections.set(input.subscriberId, {
      generation: (current?.generation ?? 0) + 1,
      lastUsed: ++this.#surfaceProjectionUseSequence,
      minVisibleObservationSequence: observation.currentObservationSequence + 1,
    });
    this.#entries.touch(entry);
    entry.boundary.assertCurrent();
    return this.#publisher.receipt();
  }
}

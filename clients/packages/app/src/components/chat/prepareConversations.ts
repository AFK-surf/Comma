import type { ChatRegistry } from "./ChatProvider";

export type ConversationPreparationTarget = {
  conversationId: string;
  groupId: string;
  updatedAt?: number | undefined;
};

// Per mounted list: six visible targets, two one-shot requests, 24 messages each.
// The existing session seed store retains at most 16 snapshots. No live channels,
// timers, polling, or retry loops are started by preparation.
export class ConversationPreparation {
  private targets: readonly ConversationPreparationTarget[] = [];
  private active = new Map<string, AbortController>();
  private attempted = new Map<string, number>();
  private disposed = false;

  constructor(private registry: ChatRegistry) {}

  update(targets: readonly ConversationPreparationTarget[]) {
    this.targets = targets.slice(0, 6);
    this.pump();
  }

  dispose() {
    this.disposed = true;
    for (const controller of this.active.values()) controller.abort();
    this.targets = [];
  }

  private pump() {
    if (this.disposed) return;
    for (const target of this.targets) {
      if (this.active.size >= 2) break;
      const key = `${target.groupId}/${target.conversationId}`;
      const version = target.updatedAt ?? 0;
      const cached = this.registry.getRetainedSnapshot(
        target.groupId,
        target.conversationId
      );
      if (
        this.active.has(key) ||
        this.attempted.get(key) === version ||
        (cached?.conversation && (cached.conversation.updated_at ?? 0) >= version)
      )
        continue;
      this.attempted.delete(key);
      this.attempted.set(key, version);
      while (this.attempted.size > 16)
        this.attempted.delete(this.attempted.keys().next().value!);
      const controller = new AbortController();
      this.active.set(key, controller);
      // Attempts fence session changes as well as component teardown. A failed
      // speculative read leaves the normal user-initiated open path in charge.
      let attempt;
      try {
        attempt = this.registry.beginAttempt();
      } catch {
        this.dispose();
        return;
      }
      void attempt
        .run((api, signal) =>
          api.getConversation(target.groupId, target.conversationId, {
            messageLimit: 24,
            signal: AbortSignal.any([signal, controller.signal]),
          })
        )
        .then((conversation) => {
          if (!this.disposed && !controller.signal.aborted && attempt.isCurrent()) {
            this.registry.rememberConversationSnapshot(conversation);
          }
        })
        .catch(() => {})
        .finally(() => {
          attempt.release();
          this.active.delete(key);
          this.pump();
        });
    }
  }
}

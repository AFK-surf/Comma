import type { ConversationEntry } from "./conversationLayout";

type TurnResponseIdentity = {
  entries: ConversationEntry[];
  /** Only aliases for canonical rows still in this mounted turn are retained. */
  canonicalKeys: ReadonlyMap<string, string>;
  nextDraftInstance: number;
  draft?:
    | {
        key: string;
        identityKey: string;
        baselineMessageId: string | undefined;
      }
    | undefined;
};

export function reconcileTurnResponseIdentity(
  previous: TurnResponseIdentity | undefined,
  entries: ConversationEntry[]
): TurnResponseIdentity {
  const canonicalIds = new Set<string>();
  let latestCanonicalId: string | undefined;
  let draftKey: string | undefined;
  for (const entry of entries) {
    if (entry.kind !== "assistant-response") continue;
    if (entry.message && !entry.message.platformSource) {
      canonicalIds.add(entry.message.messageId);
      latestCanonicalId = entry.message.messageId;
    } else if (entry.draft) {
      draftKey = entry.key;
    }
  }
  const canonicalKeys = new Map(
    [...(previous?.canonicalKeys ?? [])].filter(([id]) => canonicalIds.has(id))
  );
  const previousDraft = previous?.draft;
  if (
    previousDraft &&
    previousDraft.identityKey !== draftKey &&
    latestCanonicalId !== undefined &&
    latestCanonicalId !== previousDraft.baselineMessageId &&
    !canonicalKeys.has(latestCanonicalId)
  ) {
    // The existing channel boundary atomically replaces an observed draft with
    // the newly observed last assistant Message. This is a local visual alias,
    // not a response identity inferred for canonical Messages. Prepending older
    // rows leaves the canonical tail unchanged and cannot steal that alias.
    canonicalKeys.set(latestCanonicalId, previousDraft.key);
  }
  let nextDraftInstance = previous?.nextDraftInstance ?? 0;
  let draft: TurnResponseIdentity["draft"];
  if (draftKey !== undefined) {
    if (previousDraft?.identityKey === draftKey) {
      draft = previousDraft;
    } else {
      // response/source identifies an activation, which can send more than
      // once. Only an observed new draft lifetime allocates a visual row;
      // transport-only draftId changes within a live lifetime do not.
      draft = {
        key: `${draftKey}:instance:${nextDraftInstance++}`,
        identityKey: draftKey,
        baselineMessageId: latestCanonicalId,
      };
    }
  }
  return { entries, canonicalKeys, nextDraftInstance, draft };
}

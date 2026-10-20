import type { ChatRuntimeSession } from "@comma/chat-contract";

/**
 * A validated runtime session with only its draft replaced. The transcript
 * objects are reused, so a keystroke neither rebuilds nor re-validates them.
 */
export function withSessionDraft(
  session: ChatRuntimeSession,
  draft: string,
  draftEpoch: number
): ChatRuntimeSession {
  return {
    ...session,
    draftEpoch,
    state: { ...session.state, draft },
    ...(session.surfaceProjections
      ? {
          surfaceProjections: session.surfaceProjections.map((projection) => ({
            ...projection,
            state: { ...projection.state, draft },
          })),
        }
      : {}),
  };
}

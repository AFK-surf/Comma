import type { CommaApiClient } from "../../../api";
import type { ChatCoordinatorOptions, ChatSessionBoundApi } from "../hostContract";

/** The API a command runs against and the currency checks of its session. */
export type ChatSessionBoundary = {
  api: CommaApiClient;
  assertCurrent: () => void;
  isCurrent: () => boolean;
  key: string;
};

export class StaleChatSessionError extends Error {
  constructor() {
    super("Workspace Chat resolution was cancelled because the session changed.");
    this.name = "StaleChatSessionError";
  }
}

/**
 * Opens the boundary of each command. A Session-bound API scopes it to the
 * current session; a plain API factory is unscoped.
 */
export function sessionBoundaryOpener({
  createApi,
  createSessionBoundApi,
}: Pick<
  ChatCoordinatorOptions,
  "createApi" | "createSessionBoundApi"
>): () => ChatSessionBoundary {
  if ((createApi ? 1 : 0) + (createSessionBoundApi ? 1 : 0) !== 1) {
    throw new Error(
      "ChatCoordinator requires exactly one API or Session-bound API factory."
    );
  }
  return () => {
    if (createSessionBoundApi) {
      const binding = createSessionBoundApi();
      return {
        api: binding.api,
        assertCurrent: binding.assertCurrent,
        isCurrent: binding.isCurrent,
        key: sessionBoundaryKey(binding),
      };
    }

    return {
      api: createApi!(),
      assertCurrent: () => {},
      isCurrent: () => true,
      key: "unscoped",
    };
  };
}

/** Whether an entry opened under `held` may still serve a command under `current`. */
export function isSameLiveBoundary(
  held: ChatSessionBoundary,
  current: ChatSessionBoundary
): boolean {
  return held.key === current.key && held.isCurrent() && current.isCurrent();
}

function sessionBoundaryKey(binding: ChatSessionBoundApi) {
  return JSON.stringify([
    binding.session.authorityInstanceId,
    binding.session.generation,
    binding.session.sessionId,
    binding.session.audience,
  ]);
}

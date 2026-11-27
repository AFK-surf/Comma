// Ask Comma: the person's words go to Home as an ordinary message. Connected, the extension sends them itself.
// Not connected, or once its session ended, it hands them to the desktop app's composer for the person to send.
import { ApiError, Unauthorized, type CommaApi } from "./api";
import { composeLink } from "./links";
import type { CommaStore, Workspace } from "./store";

export type AskOutcome =
  /** Comma has the message. */
  | { kind: "sent"; workspace: Workspace }
  /** The words are in the desktop app's composer. `reconnect` when the session ended. */
  | { kind: "draft"; reconnect: boolean }
  /** The account has several Workspaces and none is chosen yet. */
  | { kind: "choose_workspace" }
  /** A link cannot carry this much text; connect to send it. */
  | { kind: "too_long" }
  /** Nothing but blank space: nothing is sent or handed over. */
  | { kind: "empty" };

export interface AskDeps {
  store: CommaStore;
  scheme: string;
  /** The API with `token`'s session. */
  api(token: string): CommaApi;
  open(url: string): Promise<void>;
  requestId(): string;
}

/**
 * Does `use` in the Workspace the extension works in: the chosen one, else the account's only one. Answers undefined
 * when the person has to choose one first.
 *
 * A chosen Workspace the account no longer has (the server answers 403 or 404) is forgotten, and the choice is made
 * again once: the commands recover without a Switch Workspace or a reconnect.
 */
export async function inWorkspace<T>(
  store: CommaStore,
  api: CommaApi,
  use: (workspace: Workspace) => Promise<T>
): Promise<{ workspace: Workspace; value: T } | undefined> {
  const chosen = await store.workspace();
  if (chosen) {
    try {
      return { workspace: chosen, value: await use(chosen) };
    } catch (error) {
      if (
        !(error instanceof ApiError) ||
        (error.status !== 403 && error.status !== 404)
      )
        throw error;
      await store.clearWorkspace();
    }
  }
  const all = await api.workspaces();
  if (all.length !== 1) return undefined;
  const only = all[0]!;
  await store.setWorkspace(only);
  return { workspace: only, value: await use(only) };
}

/**
 * Sends to the Workspace's Home. The Home found before is kept, so a message is one request. When the server no
 * longer has the kept Home (403 or 404), it is forgotten and found again once.
 */
async function sendHome(
  store: CommaStore,
  api: CommaApi,
  groupId: string,
  text: string,
  requestId: string
): Promise<void> {
  const kept = await store.home(groupId);
  if (kept) {
    try {
      return await api.send(groupId, kept, text, requestId);
    } catch (error) {
      if (
        !(error instanceof ApiError) ||
        (error.status !== 403 && error.status !== 404)
      )
        throw error;
      await store.clearHome();
    }
  }
  const conversationId = await api.home(groupId);
  await store.setHome({ groupId, conversationId });
  await api.send(groupId, conversationId, text, requestId);
}

export async function ask(text: string, deps: AskDeps): Promise<AskOutcome> {
  if (!text.trim()) return { kind: "empty" };
  const draft = async (reconnect: boolean): Promise<AskOutcome> => {
    const link = composeLink(deps.scheme, text);
    if (!link) return { kind: "too_long" };
    await deps.open(link);
    return { kind: "draft", reconnect };
  };
  const session = await deps.store.session();
  if (!session) return draft(false);
  const api = deps.api(session.token);
  try {
    const requestId = deps.requestId();
    const sent = await inWorkspace(deps.store, api, (workspace) =>
      sendHome(deps.store, api, workspace.groupId, text, requestId)
    );
    if (!sent) return { kind: "choose_workspace" };
    return { kind: "sent", workspace: sent.workspace };
  } catch (error) {
    if (!(error instanceof Unauthorized)) throw error;
    // Fail closed: the ended session is forgotten, and the words are not lost.
    await deps.store.clearSession();
    return draft(true);
  }
}

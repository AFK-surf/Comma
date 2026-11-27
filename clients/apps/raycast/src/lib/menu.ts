// What the menu bar shows. It reads one page of Tasks each time it refreshes.
import { Unauthorized, taskIsActive, type ApiTask, type CommaApi } from "./api";
import { inWorkspace } from "./ask";
import type { CommaStore, Workspace } from "./store";

export type MenuState =
  /** Nothing is known yet. */
  | { kind: "loading" }
  /** The extension has no session: the menu offers to connect. */
  | { kind: "signed_out" }
  /** The account has several Workspaces and none is chosen. */
  | { kind: "choose_workspace"; email: string }
  /** The Tasks could not be read just now. The extension is still connected. */
  | { kind: "unavailable"; email: string }
  | { kind: "ready"; email: string; workspace: Workspace; tasks: ApiTask[] };

export async function menuState(
  store: CommaStore,
  api: (token: string) => CommaApi
): Promise<MenuState> {
  const session = await store.session();
  if (!session) return { kind: "signed_out" };
  const { email } = session;
  try {
    const client = api(session.token);
    const read = await inWorkspace(store, client, (workspace) =>
      client.tasks(workspace.groupId)
    );
    if (!read) return { kind: "choose_workspace", email };
    return {
      kind: "ready",
      email,
      workspace: read.workspace,
      tasks: read.value.tasks.filter(taskIsActive),
    };
  } catch (error) {
    if (error instanceof Unauthorized) {
      await store.clearSession();
      return { kind: "signed_out" };
    }
    // Offline, a timeout, or a server fault says nothing about the session: it stays.
    return { kind: "unavailable", email };
  }
}

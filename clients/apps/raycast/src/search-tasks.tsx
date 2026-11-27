import {
  Action,
  ActionPanel,
  Icon,
  LaunchType,
  List,
  Toast,
  launchCommand,
  showToast,
} from "@raycast/api";
import { useEffect, useRef, useState } from "react";
import { Unauthorized, type ApiTask } from "./lib/api";
import { inWorkspace } from "./lib/ask";
import { taskLink } from "./lib/links";
import { createTaskSearch, type SearchView, type TaskSearch } from "./lib/search";
import type { Workspace } from "./lib/store";
import { CommaActions } from "./actions";
import { runtime } from "./runtime";

type State =
  | { kind: "loading" }
  | { kind: "signed_out" }
  | { kind: "choose_workspace" }
  | { kind: "unavailable" }
  | { kind: "ready"; workspace: Workspace; tasks: ApiTask[]; next: string | undefined };

export default function SearchTasks() {
  const [state, setState] = useState<State>({ kind: "loading" });
  const [loadingMore, setLoadingMore] = useState(false);
  /** The Workspace whose Tasks the list shows. */
  const listed = useRef<string | undefined>(undefined);
  /** What the person searches for, and the Tasks the server found. No query shows the list. */
  const [found, setFound] = useState<SearchView | undefined>(undefined);
  // One request for each query that Raycast passes on (`throttle`), for at most 20 Tasks.
  const searchRef = useRef<TaskSearch | undefined>(undefined);
  if (!searchRef.current) {
    const { store, api } = runtime();
    searchRef.current = createTaskSearch({
      store,
      api,
      onChange: setFound,
      onSignedOut: () => setState({ kind: "signed_out" }),
      onChooseWorkspace: () => setState({ kind: "choose_workspace" }),
      onError: () =>
        showToast({ style: Toast.Style.Failure, title: "Could not search Tasks" }),
    });
  }
  const search = searchRef.current;

  // One page when the list opens; the next page only when the person reaches the end.
  const load = async (cursor?: string) => {
    const { api, store } = runtime();
    const session = await store.session();
    if (!session) return setState({ kind: "signed_out" });
    const client = api(session.token);
    // A cursor belongs to the Workspace it came from: the list starts over when the Workspace is another one.
    const shown = listed.current;
    try {
      const read = await inWorkspace(store, client, (workspace) =>
        client.tasks(workspace.groupId, workspace.id === shown ? cursor : undefined)
      );
      if (!read) return setState({ kind: "choose_workspace" });
      const { workspace, value: page } = read;
      listed.current = workspace.id;
      setState((before) => ({
        kind: "ready",
        workspace,
        tasks:
          before.kind === "ready" && cursor && shown === workspace.id
            ? [...before.tasks, ...page.tasks]
            : page.tasks,
        next: page.next,
      }));
    } catch (error) {
      if (error instanceof Unauthorized) {
        await store.clearSession();
        return setState({ kind: "signed_out" });
      }
      await showToast({ style: Toast.Style.Failure, title: "Could not load Tasks" });
      // A later page that fails keeps the Tasks already shown; a first page that fails stops the loading state.
      if (!cursor) setState({ kind: "unavailable" });
    }
  };

  useEffect(() => {
    void load();
  }, []);

  const onDisconnected = () => {
    listed.current = undefined;
    setFound(undefined);
    setState({ kind: "signed_out" });
  };

  if (state.kind === "signed_out")
    return (
      <List>
        <List.EmptyView
          icon={Icon.Link}
          title="Connect Comma to see your Tasks"
          description="Press Return to connect, then confirm in the Comma app."
          actions={
            <ActionPanel>
              <Action
                title="Connect Comma"
                icon={Icon.Link}
                onAction={() =>
                  launchCommand({ name: "connect", type: LaunchType.UserInitiated })
                }
              />
              <CommaActions connected={false} />
            </ActionPanel>
          }
        />
      </List>
    );
  if (state.kind === "choose_workspace")
    return (
      <List>
        <List.EmptyView
          icon={Icon.Building}
          title="Choose a Workspace"
          description="Press Return to choose the Workspace."
          actions={
            <ActionPanel>
              <Action
                title="Switch Workspace"
                icon={Icon.Building}
                onAction={() =>
                  launchCommand({
                    name: "switch-workspace",
                    type: LaunchType.UserInitiated,
                  })
                }
              />
              <CommaActions onDisconnected={onDisconnected} />
            </ActionPanel>
          }
        />
      </List>
    );
  // Search results already shown stay when the first page fails; an empty search bar shows the failure.
  if (state.kind === "unavailable" && !found)
    return (
      <List>
        <List.EmptyView
          icon={Icon.Warning}
          title="Could not load Tasks"
          description="Press Return to try again."
          actions={
            <ActionPanel>
              <Action
                title="Try Again"
                icon={Icon.ArrowClockwise}
                onAction={() => {
                  setState({ kind: "loading" });
                  void load();
                }}
              />
              <CommaActions onDisconnected={onDisconnected} />
            </ActionPanel>
          }
        />
      </List>
    );

  const ready = state.kind === "ready" ? state : undefined;
  const { scheme } = runtime();
  return (
    <List
      isLoading={state.kind === "loading" || loadingMore || found?.loading === true}
      searchBarPlaceholder="Search your Tasks"
      onSearchTextChange={(typed) => void search.run(typed)}
      throttle
      actions={
        <ActionPanel>
          <CommaActions
            connected={state.kind !== "loading"}
            onDisconnected={onDisconnected}
          />
        </ActionPanel>
      }
      pagination={
        ready && !found
          ? {
              pageSize: 50,
              hasMore: ready.next !== undefined,
              onLoadMore: () => {
                if (!ready.next || loadingMore) return;
                setLoadingMore(true);
                void load(ready.next).finally(() => setLoadingMore(false));
              },
            }
          : undefined
      }
    >
      {found?.failed && (
        <List.EmptyView
          icon={Icon.Warning}
          title="Could not search Tasks"
          description="Press Return to try again."
          actions={
            <ActionPanel>
              <Action
                title="Try Again"
                icon={Icon.ArrowClockwise}
                onAction={() => void search.run(found.query, { force: true })}
              />
              <CommaActions onDisconnected={onDisconnected} />
            </ActionPanel>
          }
        />
      )}
      {found && !found.loading && !found.failed && found.hits?.length === 0 && (
        <List.EmptyView
          icon={Icon.MagnifyingGlass}
          title="No Tasks found"
          actions={
            <ActionPanel>
              <CommaActions onDisconnected={onDisconnected} />
            </ActionPanel>
          }
        />
      )}
      {ready && !found && ready.tasks.length === 0 && (
        <List.EmptyView
          icon={Icon.Tray}
          title="No Tasks yet"
          description="Use Ask Comma or open Comma to start one."
          actions={
            <ActionPanel>
              <CommaActions onDisconnected={onDisconnected} />
            </ActionPanel>
          }
        />
      )}
      {(found?.failed ? [] : (found?.hits ?? [])).map((hit) => (
        <List.Item
          key={hit.conversationId}
          title={hit.title}
          subtitle={
            hit.matchedField === "content" && hit.snippet ? hit.snippet : undefined
          }
          actions={
            <ActionPanel>
              {found?.workspace && (
                <Action.Open
                  title="Open in Comma"
                  target={taskLink(scheme, {
                    workspaceId: found.workspace.id,
                    groupId: hit.groupId,
                    conversationId: hit.conversationId,
                  })}
                />
              )}
              <CommaActions onDisconnected={onDisconnected} />
            </ActionPanel>
          }
        />
      ))}
      {(found ? [] : (ready?.tasks ?? [])).map((task) => (
        <List.Item
          key={task.conversationId}
          title={task.title}
          accessories={task.status ? [{ tag: task.status.replaceAll("_", " ") }] : []}
          actions={
            <ActionPanel>
              <Action.Open
                title="Open in Comma"
                target={taskLink(scheme, {
                  workspaceId: ready!.workspace.id,
                  groupId: task.groupId,
                  conversationId: task.conversationId,
                })}
              />
              <CommaActions onDisconnected={onDisconnected} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}

import {
  Action,
  ActionPanel,
  Icon,
  LaunchType,
  List,
  Toast,
  launchCommand,
  popToRoot,
  showHUD,
  showToast,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { Unauthorized, type ApiWorkspace } from "./lib/api";
import { CommaActions } from "./actions";
import { runtime } from "./runtime";

export default function SwitchWorkspace() {
  const [workspaces, setWorkspaces] = useState<ApiWorkspace[]>();
  const [chosen, setChosen] = useState<string>();
  const [signedOut, setSignedOut] = useState(false);
  const [loadFailed, setLoadFailed] = useState(false);

  const load = async () => {
    setWorkspaces(undefined);
    setLoadFailed(false);
    const { api, store } = runtime();
    const session = await store.session();
    if (!session) return setSignedOut(true);
    setChosen((await store.workspace())?.id);
    try {
      setWorkspaces(await api(session.token).workspaces());
    } catch (error) {
      if (error instanceof Unauthorized) {
        await store.clearSession();
        return setSignedOut(true);
      }
      await showToast({
        style: Toast.Style.Failure,
        title: "Could not load Workspaces",
      });
      setLoadFailed(true);
      setWorkspaces([]);
    }
  };

  useEffect(() => {
    void load();
  }, []);

  const onDisconnected = () => {
    setWorkspaces(undefined);
    setChosen(undefined);
    setLoadFailed(false);
    setSignedOut(true);
  };

  if (signedOut)
    return (
      <List>
        <List.EmptyView
          icon={Icon.Link}
          title="Connect Comma first"
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

  return (
    <List
      isLoading={workspaces === undefined}
      actions={
        <ActionPanel>
          <CommaActions
            connected={workspaces !== undefined}
            onDisconnected={onDisconnected}
          />
        </ActionPanel>
      }
    >
      {workspaces?.length === 0 && loadFailed && (
        <List.EmptyView
          icon={Icon.Warning}
          title="Could not load Workspaces"
          description="Press Return to try again."
          actions={
            <ActionPanel>
              <Action
                title="Try Again"
                icon={Icon.ArrowClockwise}
                onAction={() => void load()}
              />
              <CommaActions onDisconnected={onDisconnected} />
            </ActionPanel>
          }
        />
      )}
      {workspaces?.length === 0 && !loadFailed && (
        <List.EmptyView
          icon={Icon.Building}
          title="No Workspaces found"
          actions={
            <ActionPanel>
              <CommaActions onDisconnected={onDisconnected} />
            </ActionPanel>
          }
        />
      )}
      {workspaces?.map((workspace) => (
        <List.Item
          key={workspace.id}
          title={workspace.name}
          icon={workspace.id === chosen ? Icon.CheckCircle : Icon.Circle}
          actions={
            <ActionPanel>
              <Action
                title="Use This Workspace"
                onAction={async () => {
                  await runtime().store.setWorkspace(workspace);
                  await showHUD(`Comma uses ${workspace.name}`);
                  await popToRoot();
                }}
              />
              <CommaActions onDisconnected={onDisconnected} />
            </ActionPanel>
          }
        />
      ))}
    </List>
  );
}

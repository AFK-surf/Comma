import {
  Icon,
  LaunchType,
  MenuBarExtra,
  launchCommand,
  open,
  showHUD,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { homeLink, taskLink } from "./lib/links";
import { menuState, type MenuState } from "./lib/menu";
import { disconnect, runtime } from "./runtime";

/** Opens a Comma link. The menu bar has no toast, so a link nothing takes is said in a HUD. */
const openInComma = (url: string) =>
  open(url).catch(() => showHUD("Could not open Comma. Is the Comma app installed?"));

const run = (name: string) => launchCommand({ name, type: LaunchType.UserInitiated });

// One request for one page each time the menu refreshes (every 5 minutes, and when it is opened).
export default function MenuBar() {
  const [state, setState] = useState<MenuState>({ kind: "loading" });

  useEffect(() => {
    const { api, store } = runtime();
    void menuState(store, api).then(setState);
  }, []);

  const { scheme } = runtime();
  const tasks = state.kind === "ready" ? state.tasks : [];
  return (
    <MenuBarExtra
      icon="icon.png"
      isLoading={state.kind === "loading"}
      title={tasks.length > 0 ? String(tasks.length) : undefined}
      tooltip="Comma"
    >
      {state.kind === "signed_out" ? (
        <MenuBarExtra.Item
          icon={Icon.Link}
          title="Connect Comma"
          onAction={() => run("connect")}
        />
      ) : null}
      {state.kind === "choose_workspace" ? (
        <MenuBarExtra.Item
          icon={Icon.Building}
          title="Choose a Workspace"
          onAction={() => run("switch-workspace")}
        />
      ) : null}
      {state.kind === "unavailable" ? (
        <MenuBarExtra.Item icon={Icon.Warning} title="Could not load Tasks" />
      ) : null}
      {state.kind === "ready" ? (
        <MenuBarExtra.Section
          title={tasks.length > 0 ? "Active Tasks" : "No active Tasks"}
        >
          {tasks.slice(0, 10).map((task) => (
            <MenuBarExtra.Item
              key={task.conversationId}
              title={task.title}
              onAction={() =>
                openInComma(
                  taskLink(scheme, {
                    workspaceId: state.workspace.id,
                    groupId: task.groupId,
                    conversationId: task.conversationId,
                  })
                )
              }
            />
          ))}
        </MenuBarExtra.Section>
      ) : null}
      <MenuBarExtra.Section>
        <MenuBarExtra.Item
          title="Open Comma"
          onAction={() => openInComma(homeLink(scheme))}
        />
        {"email" in state ? <MenuBarExtra.Item title={state.email} /> : null}
        {"email" in state ? (
          <MenuBarExtra.Item
            icon={Icon.Logout}
            title="Disconnect Comma"
            onAction={() =>
              disconnect({
                toast: false,
                onDisconnected: () => setState({ kind: "signed_out" }),
              })
            }
          />
        ) : null}
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}

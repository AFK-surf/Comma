// The actions every list of the extension offers. They stand in for commands: an organization's free plan on
// Raycast allows 5 commands, so Open Comma and Disconnect Comma are actions.
import { Action, ActionPanel, Icon } from "@raycast/api";
import { disconnect, openComma } from "./runtime";

export function CommaActions({
  connected = true,
  onDisconnected,
}: {
  connected?: boolean;
  onDisconnected?: () => void;
}) {
  return (
    <ActionPanel.Section>
      <Action title="Open Comma" icon={Icon.AppWindow} onAction={openComma} />
      {connected ? (
        <Action
          title="Disconnect Comma"
          icon={Icon.Logout}
          style={Action.Style.Destructive}
          onAction={() => disconnect({ onDisconnected })}
        />
      ) : null}
    </ActionPanel.Section>
  );
}

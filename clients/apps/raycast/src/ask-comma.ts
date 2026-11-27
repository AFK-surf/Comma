import {
  Alert,
  Clipboard,
  LaunchProps,
  LaunchType,
  Toast,
  confirmAlert,
  launchCommand,
  showHUD,
  showToast,
} from "@raycast/api";
import { ask } from "./lib/ask";
import { reportedMissingApp, runtime } from "./runtime";

export default async function AskComma(
  props: LaunchProps<{ arguments: { text: string } }>
) {
  const text = props.arguments.text;
  if (!text.trim()) {
    await showToast({ style: Toast.Style.Failure, title: "Enter a message to send" });
    return;
  }
  const deps = runtime();
  const hasSession = Boolean(await deps.store.session());
  if (!hasSession) {
    const connect = await confirmAlert({
      title: "Connect Comma to send from Raycast",
      message:
        "Raycast is not connected to your Comma account. Connect now to send from Raycast. Your words are copied so that you can ask again.",
      primaryAction: { title: "Connect Comma" },
      dismissAction: { title: "Cancel", style: Alert.ActionStyle.Cancel },
    });
    if (!connect) return;
    try {
      await Clipboard.copy(text);
      await launchCommand({ name: "connect", type: LaunchType.UserInitiated });
    } catch {
      await showToast({
        style: Toast.Style.Failure,
        title: "Could not start Connect Comma",
        message: "Run Connect Comma from Raycast to connect.",
      });
    }
    return;
  }
  const toast = await showToast({
    style: Toast.Style.Animated,
    title: "Sending to Comma",
  });
  try {
    const outcome = await ask(text, deps);
    if (outcome.kind === "sent") {
      await showHUD("Sent to Comma");
    } else if (outcome.kind === "draft") {
      await showHUD(
        outcome.reconnect
          ? "Comma signed this extension out. Send it in Comma, then run Connect Comma."
          : "Press Return in Comma to send"
      );
    } else if (outcome.kind === "choose_workspace") {
      toast.style = Toast.Style.Failure;
      toast.title = "Choose a Workspace first";
      await launchCommand({ name: "switch-workspace", type: LaunchType.UserInitiated });
    } else if (outcome.kind === "too_long") {
      toast.style = Toast.Style.Failure;
      toast.title = "That is too long to hand to Comma";
      toast.message = "Run Connect Comma to send long messages.";
    } else {
      toast.style = Toast.Style.Failure;
      toast.title = "Enter a message to send";
    }
  } catch (error) {
    if (await reportedMissingApp(error)) return;
    toast.style = Toast.Style.Failure;
    toast.title = "Comma did not take the message";
    toast.message = "Nothing was sent. Try again.";
  }
}

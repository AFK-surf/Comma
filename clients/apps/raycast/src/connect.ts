import { LaunchProps, Toast, showHUD, showToast } from "@raycast/api";
import { ConnectError, beginConnect, finishConnect } from "./lib/connect";
import { reportedMissingApp, runtime } from "./runtime";

// Run by the person, it asks the Comma app to connect. Opened by Comma's link, it carries the pairing to finish with.
export default async function Connect(props: LaunchProps) {
  const { api, open, platform, scheme, store } = runtime();
  const now = Date.now;
  if (props.launchContext === undefined) {
    try {
      await beginConnect({ store, scheme, now, open });
      await showHUD("Confirm in Comma to connect");
    } catch (error) {
      // Nothing waits for a pairing when Comma never got the request.
      await store.clearPending();
      if (!(await reportedMissingApp(error))) throw error;
    }
    return;
  }
  try {
    const session = await finishConnect(props.launchContext, {
      store,
      api: api(),
      now,
      platform,
    });
    await showHUD(`Connected to Comma as ${session.email}`);
  } catch (error) {
    const notStarted = error instanceof ConnectError && error.reason === "not_started";
    await showToast({
      style: Toast.Style.Failure,
      title: notStarted ? "No connection is waiting" : "Comma refused the connection",
      message: "Run Connect Comma to start again.",
    });
  }
}

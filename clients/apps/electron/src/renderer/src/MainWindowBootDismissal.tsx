import { useLayoutEffect } from "react";
import { useSessionHostController, useSessionLifecycleSnapshot } from "@comma/app";
import { dismissMainWindowBoot } from "./mainWindowBoot";

// The boot covers startup until Session truth is known. Remove it in the commit
// that renders the first Session screen, so no blank frame shows between them.
export function MainWindowBootDismissal() {
  const { lifecycle } = useSessionHostController();
  const phase = useSessionLifecycleSnapshot(lifecycle).phase;
  useLayoutEffect(() => {
    if (phase !== "initializing") dismissMainWindowBoot();
  }, [phase]);
  return null;
}

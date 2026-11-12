import { useEffect } from "react";
import { createPortal } from "react-dom";
import { DeviceScreen } from "./DeviceScreenPanel";
import { closeScreenWindows, useScreenWindows } from "./screenWindows";

/**
 * Renders the screens shown in windows of their own into those windows, from this page: one React tree, one stream
 * a screen. Mounted once a signed-in session; the windows close as it goes.
 */
export function ScreenWindowHost() {
  const windows = useScreenWindows();
  useEffect(() => closeScreenWindows, []);
  return windows.map((shown) =>
    createPortal(
      <DeviceScreen active page={shown.page} place="window" />,
      shown.root,
      shown.id
    )
  );
}

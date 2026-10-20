// Pages in the browser sidebar partition, including sign-in popups and
// iframes, run this preload. It exposes nothing to the page and opens no IPC.
import { contextBridge } from "electron";
import { installBrowserPageWebAuthnGuard } from "./preload/browser-page-webauthn";

// On Windows, Chromium hands passkey requests to Windows' own WebAuthn, whose
// dialog offers Windows Hello, passkey apps such as 1Password, a phone and
// security keys: the guard leaves those requests to it and holds back only
// passkey autofill.
contextBridge.executeInMainWorld({
  func: installBrowserPageWebAuthnGuard,
  args: [undefined, undefined, process.platform === "win32"],
});

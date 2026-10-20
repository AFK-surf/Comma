import { app } from "electron";
import { VelopackApp } from "velopack";
import { getCommaReleaseConfig } from "./release-config";

VelopackApp.build()
  // What Windows keeps of the app outside its folder, which the uninstaller
  // does not remove: launch at login and the comma:// link (the registry's).
  .onBeforeUninstallFastCallback(() => {
    if (process.platform !== "win32") return;
    app.setLoginItemSettings({ openAtLogin: false });
    app.removeAsDefaultProtocolClient(getCommaReleaseConfig().urlScheme);
  })
  .run();

void bootstrapMain();

async function bootstrapMain() {
  await import("./main/index");
}

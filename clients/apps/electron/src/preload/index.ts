/// <reference lib="dom" />
import { contextBridge, ipcRenderer, webUtils } from "electron";
import { installCommaNativeMainWorldBridge } from "./native-bridge-main-world";
import { createNativeBridgePreload } from "./native-bridge";

const nativeBridgePreloadKey = "__commaNativePreload";

if (window.top === window) {
  contextBridge.exposeInMainWorld(
    nativeBridgePreloadKey,
    createNativeBridgePreload(ipcRenderer, {
      getPathForFile: webUtils.getPathForFile,
    })
  );
  contextBridge.executeInMainWorld({
    args: [nativeBridgePreloadKey, "commaNative"],
    func: installCommaNativeMainWorldBridge,
  });
}

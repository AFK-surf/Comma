import type { NativeInfo } from "@comma/native-bridge";
import { createContext, useContext } from "react";

/** The host's native info, resolved once by the root layout. */
export const NativeInfoContext = createContext<NativeInfo>({
  appVersion: "unknown",
  os: "unknown",
  platform: "web",
});

export function useNativeInfoContext() {
  return useContext(NativeInfoContext);
}

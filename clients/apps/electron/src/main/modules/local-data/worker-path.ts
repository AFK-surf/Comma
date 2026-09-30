import { join } from "node:path";

export const LOCAL_DATA_UTILITY_BUNDLE_FILENAME = "utility.js";

export function resolveLocalDataUtilityModulePath(
  mainBundleDirectory: string = __dirname
): string {
  return join(mainBundleDirectory, LOCAL_DATA_UTILITY_BUNDLE_FILENAME);
}

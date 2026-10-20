// The build of the browser component tests' pages, on its own: runs that
// start together (CI shards) share it (COMMA_APP_SHELL_PAGES=prebuilt).
//
//   pnpm exec vite build -c e2e/app-shell/pages.vite.config.ts
import { appShellPagesBuild } from "../../vitest.config";

const { configFile: _none, ...config } = appShellPagesBuild();
export default config;

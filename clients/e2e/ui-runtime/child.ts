// The entry of a browser component test's page on the UI runtime. The host's
// functions are the runtime's before any other module of the page loads
// (React's scheduler makes its message channel when it loads); the page itself
// is ./child-page.ts.
import { installTestUiHost } from "../../packages/ui/src/runtime/test/testing";

installTestUiHost({ layout: true });
// The build reports each dynamic import to the page (vitest.config.ts,
// trackDynamicImports); ./child-page.ts takes the reports over when it loads.
(
  globalThis as { commaTrackImport?: <T>(loading: Promise<T>) => Promise<T> }
).commaTrackImport = (loading) => loading;
await import("./child-page");

import { resolve } from "node:path";
import { build } from "esbuild";

// The shipped runtime, built and loaded when a frame first asks for its
// document, as the Electron spec loads it (apps/electron/e2e/dynamic-ui).
type DynamicUiRuntime = { dynamicUiCsp: string; dynamicUiDocument(): string };
let loaded: Promise<DynamicUiRuntime> | undefined;
const runtime = () =>
  (loaded ??= build({
    entryPoints: [
      resolve(
        import.meta.dirname,
        "../packages/chat-contract/src/dynamic-ui/runtime.ts"
      ),
    ],
    bundle: true,
    platform: "node",
    format: "cjs",
    write: false,
    logLevel: "silent",
  }).then((result) => {
    const module = { exports: {} as DynamicUiRuntime };
    new Function("module", "exports", result.outputFiles[0]!.text)(
      module,
      module.exports
    );
    return module.exports;
  }));

// The dynamic UI runtime's document as a test page's sandboxed frame loads it
// (e2e/ui-runtime/frame-realm.ts): the document the app ships, with its
// content security policy, and before its own script the frame's realm. The
// policy admits no script of another origin but inline ones, so the realm is
// inline: one bundle, its workers' realm inside it as text.

const root = resolve(import.meta.dirname, "..");

async function bundle(entry: string, alias: Record<string, string>, define = {}) {
  const result = await build({
    entryPoints: [resolve(root, entry)],
    bundle: true,
    format: "iife",
    platform: "browser",
    target: "es2022",
    write: false,
    alias,
    define,
    logLevel: "silent",
  });
  return result.outputFiles[0]!.text;
}

let document: Promise<string> | undefined;

/** The frame's document, built once for the run. */
export function dynamicUiFrameDocument(alias: Record<string, string>) {
  document ??= (async () => {
    const worker = await bundle("e2e/ui-runtime/worker-prelude.ts", alias);
    const frame = await bundle("e2e/ui-runtime/frame-realm.ts", alias, {
      COMMA_FRAME_WORKER_PRELUDE: JSON.stringify(worker),
    });
    // An inline script ends at the first `</script`, wherever it is.
    const inline = frame.replaceAll("</script", "<\\/script");
    const { dynamicUiDocument } = await runtime();
    // An error of the frame's scripts goes on its document, where the test
    // reads it (e2e/app-shell/support/frames.ts): the test cannot reach the
    // frame's console.
    const errors =
      "<script>addEventListener('error',(e)=>{document.documentElement.dataset.commaFrameError=String(e.message)})</script>";
    return dynamicUiDocument().replace(
      "<head>",
      `<head>${errors}<script>${inline}</script>`
    );
  })();
  return document;
}

/** The test server's answer for the frame's document (vite/parse-failure-watch.ts, ServedFiles). */
export function servedDynamicUiFrame(alias: Record<string, string>) {
  return {
    prefix: "/__dynamic-ui/",
    async read(path: string) {
      if (path !== "runtime") return undefined;
      return {
        body: Buffer.from(await dynamicUiFrameDocument(alias)),
        contentType: "text/html",
        headers: { "Content-Security-Policy": (await runtime()).dynamicUiCsp },
      };
    },
  };
}

let query: Promise<string> | undefined;

/** The locators of a frame, as a script for an isolated world of it (e2e/ui-runtime/frame-query.ts). */
export function frameQueryEngine(alias: Record<string, string>) {
  query ??= bundle("e2e/ui-runtime/frame-query.ts", alias);
  return query;
}

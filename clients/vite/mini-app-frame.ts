import { createHash } from "node:crypto";
import { resolve } from "node:path";
import { build } from "esbuild";

// The Comma app runtime's document as a test page's sandboxed frame loads it
// (e2e/app-shell/mini-app-runtime.chromium.test.ts): the document the app
// ships, with its policy, and before its own script the frame's realm
// (e2e/ui-runtime/frame-realm.ts), as for the dynamic UI runtime
// (./dynamic-ui-frame.ts). The policy admits inline scripts only by hash, so
// the policy the test serves adds the hashes of the realm's two scripts and
// nothing else.

type MiniAppRuntime = { miniAppRuntimeCsp: string; miniAppRuntimeDocument(): string };

const root = resolve(import.meta.dirname, "..");

let loaded: Promise<MiniAppRuntime> | undefined;
const runtime = () =>
  (loaded ??= build({
    entryPoints: [resolve(root, "packages/chat-contract/src/mini-app/runtime.ts")],
    bundle: true,
    platform: "node",
    format: "cjs",
    write: false,
    logLevel: "silent",
  }).then((result) => {
    const module = { exports: {} as MiniAppRuntime };
    new Function("module", "exports", result.outputFiles[0]!.text)(
      module,
      module.exports
    );
    return module.exports;
  }));

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

const hash = (script: string) =>
  `'sha256-${createHash("sha256").update(script).digest("base64")}'`;

let served: Promise<{ body: string; csp: string }> | undefined;

function miniAppFrame(alias: Record<string, string>) {
  served ??= (async () => {
    const worker = await bundle("e2e/ui-runtime/worker-prelude.ts", alias);
    const frame = await bundle("e2e/ui-runtime/frame-realm.ts", alias, {
      COMMA_FRAME_WORKER_PRELUDE: JSON.stringify(worker),
    });
    const realm = frame.replaceAll("</script", "<\\/script");
    // An error of the frame's scripts goes on its document, where the test reads it.
    const errors =
      "addEventListener('error',(e)=>{document.documentElement.dataset.commaFrameError=String(e.message)})";
    const { miniAppRuntimeCsp, miniAppRuntimeDocument } = await runtime();
    return {
      body: miniAppRuntimeDocument().replace(
        "<head>",
        `<head><script>${errors}</script><script>${realm}</script>`
      ),
      csp: miniAppRuntimeCsp.replace(
        "script-src ",
        `script-src ${hash(errors)} ${hash(realm)} `
      ),
    };
  })();
  return served;
}

/** The test server's answer for the frame's document (vite/parse-failure-watch.ts, ServedFiles). */
export function servedMiniAppFrame(alias: Record<string, string>) {
  return {
    prefix: "/__mini-app/",
    async read(path: string) {
      if (path !== "runtime") return undefined;
      const { body, csp } = await miniAppFrame(alias);
      return {
        body: Buffer.from(body),
        contentType: "text/html",
        headers: { "Content-Security-Policy": csp },
      };
    },
  };
}

import { expect, type Page } from "@playwright/test";
import { createRequire } from "node:module";
import { build } from "vite";

const require = createRequire(import.meta.url);
let clockBundle: Promise<string> | undefined;

function bundledClock() {
  return (clockBundle ??= build({
    configFile: false,
    logLevel: "silent",
    build: {
      write: false,
      minify: false,
      lib: {
        entry: require.resolve("@sinonjs/fake-timers"),
        name: "CommaFakeTimers",
        formats: ["iife"],
      },
    },
  }).then((result) => {
    for (const output of Array.isArray(result) ? result : [result]) {
      if (!("output" in output)) continue;
      const chunk = output.output.find((item) => item.type === "chunk");
      if (chunk?.type === "chunk") return chunk.code;
    }
    throw new Error("Could not bundle the SharedWorker test clock");
  }));
}

/** Control the real runtime owner, not a renderer mock or a shortened deadline. */
export async function installSharedWorkerClock(page: Page) {
  const browser = page.context().browser();
  if (!browser) throw new Error("SharedWorker clock requires a Chromium browser");
  const pageSession = await page.context().newCDPSession(page);
  const { targetInfo: pageTarget } = await pageSession.send("Target.getTargetInfo");
  await pageSession.detach();
  const session = await browser.newBrowserCDPSession();
  let workerSession: string | undefined;
  let nextId = 0;

  async function evaluate(expression: string) {
    const sessionId = workerSession;
    if (!sessionId) throw new Error("SharedWorker clock is not attached");
    const id = ++nextId;
    // Non-flattened attachment lets the public CDPSession route worker replies.
    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(
        () => finish(new Error("SharedWorker clock timed out")),
        10_000
      );
      const finish = (error?: Error, value?: unknown) => {
        clearTimeout(timer);
        session.off("Target.receivedMessageFromTarget", onMessage);
        if (error) reject(error);
        else resolve(value);
      };
      const onMessage = (event: { sessionId: string; message: string }) => {
        if (event.sessionId !== sessionId) return;
        const response = JSON.parse(event.message);
        if (response.id !== id) return;
        if (response.error || response.result?.exceptionDetails) {
          finish(
            new Error(
              JSON.stringify(response.error ?? response.result.exceptionDetails)
            )
          );
        } else finish(undefined, response.result?.result?.value);
      };
      session.on("Target.receivedMessageFromTarget", onMessage);
      void session
        .send("Target.sendMessageToTarget", {
          sessionId,
          message: JSON.stringify({
            id,
            method: "Runtime.evaluate",
            params: { expression, awaitPromise: true, returnByValue: true },
          }),
        })
        .catch((error: Error) => finish(error));
    });
  }

  try {
    let targetId: string | undefined;
    await expect
      .poll(async () => {
        const { targetInfos } = await session.send("Target.getTargets");
        const targets = targetInfos.filter(
          (target) =>
            target.type === "shared_worker" &&
            target.browserContextId === pageTarget.browserContextId &&
            target.url.includes("app-runtime.shared-worker")
        );
        targetId = targets.length === 1 ? targets[0]?.targetId : undefined;
        return targets.length;
      })
      .toBe(1);
    const attached = await session.send("Target.attachToTarget", {
      targetId: targetId!,
      flatten: false,
    });
    workerSession = attached.sessionId;
    await evaluate(`${await bundledClock()}; globalThis.__commaTestClock = CommaFakeTimers.install({
      now: Date.now(), toFake: ["Date", "setTimeout", "clearTimeout"], shouldClearNativeTimers: true
    }); undefined`);
    return {
      advance: (milliseconds: number) =>
        evaluate(`globalThis.__commaTestClock.tickAsync(${milliseconds})`),
      async dispose() {
        try {
          await evaluate(
            "globalThis.__commaTestClock.uninstall(); delete globalThis.__commaTestClock"
          );
        } finally {
          await session.detach();
        }
      },
    };
  } catch (error) {
    await session.detach();
    throw error;
  }
}

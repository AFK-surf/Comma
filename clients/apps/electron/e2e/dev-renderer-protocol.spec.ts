import { type ElectronApplication } from "@playwright/test";
import {
  electron,
  electronTestCertificate,
  expect,
  test,
  trackElectronTestResource,
} from "./electron-test";
import { mkdtemp, rm } from "node:fs/promises";
import {
  createSecureServer,
  type Http2ServerResponse,
  type ServerHttp2Session,
} from "node:http2";
import type { Socket } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";
import { closeElectronTestApp } from "./close-electron-test-app";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const stalledAssetCount = 32;

test("renderer reload cancels stalled dev assets and admits the fresh document", async () => {
  const stub = await startDevRendererStub();
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  let app: ElectronApplication | undefined;
  let userDataDir: string | undefined;

  try {
    userDataDir = await mkdtemp(join(tmpdir(), "comma-dev-protocol-e2e-"));
    app = await electron.launch({
      args: [electronMain, "--user-data-dir=" + userDataDir],
      cwd: electronAppDir,
      env: {
        ...hostEnv,
        COMMA_ELECTRON_E2E_DEV_RENDERER_URL: stub.baseUrl,
        COMMA_ELECTRON_E2E_OPERATING_SYSTEM: "linux",
        NODE_ENV: "test",
      },
    });
    const mainWindow = await findElectronWindowByNativeRole(app, "main-window");
    await expect(mainWindow.locator("body")).toHaveAttribute("data-generation", "1");
    // One of the 32 total loader permits stays reserved for a replacement
    // document, so only 31 of the 32 requested old assets may reach upstream
    // before reload.
    await expect.poll(() => stub.slowRequestCount).toBe(stalledAssetCount - 1);
    expect(stub.activeSlowResponses).toBe(stalledAssetCount - 1);
    expect(stub.http2RequestCount).toBe(stalledAssetCount);

    await mainWindow.reload({ waitUntil: "domcontentloaded" });

    await expect(mainWindow.locator("body")).toHaveAttribute("data-generation", "2");
    expect(stub.documentRequestCount).toBe(2);
    // The 32nd old request was already waiting inside the protocol handler.
    // Once an old body releases an asset permit it may reach upstream, but its
    // disconnected native consumer must immediately cancel the returned body.
    await expect.poll(() => stub.slowRequestCount).toBe(stalledAssetCount);
    await expect.poll(() => stub.activeSlowResponses).toBe(0);
  } finally {
    try {
      if (app) await closeElectronTestApp(app);
    } finally {
      try {
        await stub.close();
      } finally {
        if (userDataDir) {
          await rm(userDataDir, { force: true, recursive: true });
        }
      }
    }
  }
});

async function startDevRendererStub() {
  // The app trusts this certificate from its launch.
  const certificate = electronTestCertificate();
  let activeSlowResponses = 0;
  let documentRequestCount = 0;
  let http2RequestCount = 0;
  let slowRequestCount = 0;
  const pendingResponses = new Set<Http2ServerResponse>();
  const sessions = new Set<ServerHttp2Session>();
  const sockets = new Set<Socket>();
  const server = createSecureServer(
    {
      allowHTTP1: true,
      cert: certificate.cert,
      key: certificate.key,
    },
    (request, response) => {
      if (request.httpVersionMajor === 2) http2RequestCount += 1;
      const url = new URL(request.url ?? "/", "http://127.0.0.1");

      if (url.pathname === "/") {
        documentRequestCount += 1;
        response.writeHead(200, {
          "cache-control": "no-store",
          "content-type": "text/html; charset=utf-8",
        });
        response.end(rendererDocument(documentRequestCount));
        return;
      }

      if (url.pathname.startsWith("/stalled-asset-")) {
        slowRequestCount += 1;
        activeSlowResponses += 1;
        pendingResponses.add(response);
        let settled = false;
        const settle = () => {
          if (settled) return;
          settled = true;
          activeSlowResponses -= 1;
          pendingResponses.delete(response);
        };
        response.once("close", settle);
        response.once("finish", settle);
        response.writeHead(200, {
          "cache-control": "no-store",
          "content-type": "text/javascript; charset=utf-8",
        });
        response.write("/* response body remains open until navigation cancels it */");
        return;
      }

      response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
      response.end("Not found");
    }
  );
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  server.on("session", (session) => {
    sessions.add(session);
    session.once("close", () => sessions.delete(session));
  });
  let closed = false;
  // An HTTP/2 server of its own (the transport is what the test exercises), recorded as the test's like any other.
  const forget = trackElectronTestResource({
    name: "dev renderer stub (HTTP/2)",
    open: () => server.listening,
    dispose: () => close(),
  });
  const close = async () => {
    forget();
    if (closed) return;
    closed = true;
    for (const response of pendingResponses) response.destroy();
    for (const session of sessions) session.destroy();
    for (const socket of sockets) socket.destroy();
    if (server.listening) {
      await new Promise<void>((resolveClose, rejectClose) => {
        server.close((error) => (error ? rejectClose(error) : resolveClose()));
      });
    }
  };

  let address: ReturnType<typeof server.address>;
  try {
    await new Promise<void>((resolveListen, rejectListen) => {
      server.once("error", rejectListen);
      server.listen(0, "127.0.0.1", () => {
        server.off("error", rejectListen);
        resolveListen();
      });
    });
    address = server.address();
    if (!address || typeof address === "string") {
      throw new Error("Dev renderer stub did not bind a TCP port.");
    }
  } catch (error) {
    await close();
    throw error;
  }

  return {
    get activeSlowResponses() {
      return activeSlowResponses;
    },
    baseUrl: "https://127.0.0.1:" + address.port + "/",
    close,
    get documentRequestCount() {
      return documentRequestCount;
    },
    get http2RequestCount() {
      return http2RequestCount;
    },
    get slowRequestCount() {
      return slowRequestCount;
    },
  };
}

function rendererDocument(generation: number) {
  const assetLoader =
    generation === 1
      ? [
          "<script>",
          "globalThis.__commaPendingAssetReads = Array.from(",
          "  { length: " + stalledAssetCount + " },",
          "  (_, index) => fetch(",
          '    "assets://./stalled-asset-" + index + ".js"',
          "  ).then(async (response) => {",
          "    const reader = response.body.getReader();",
          "    while (!(await reader.read()).done) {}",
          "  })",
          ");",
          "</script>",
        ].join("\n")
      : "";

  return [
    "<!doctype html>",
    "<html>",
    '<head><meta charset="utf-8"><title>Dev renderer protocol fixture</title></head>',
    '<body data-generation="' + generation + '">generation ' + generation + "</body>",
    assetLoader,
    "</html>",
  ].join("\n");
}

import {
  _electron as electron,
  expect,
  test,
  type ElectronApplication,
} from "@playwright/test";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import {
  createSecureServer,
  type Http2ServerResponse,
  type ServerHttp2Session,
} from "node:http2";
import type { Socket } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { findElectronWindowByNativeRole } from "../src/test-support/electron-native-window";

const electronAppDir = resolve(process.cwd(), "apps/electron");
const electronMain = resolve(electronAppDir, ".vite/build/main.js");
const stalledAssetCount = 32;
const execFileAsync = promisify(execFile);

test("renderer reload cancels stalled dev assets and admits the fresh document", async () => {
  const stub = await startDevRendererStub();
  const { ELECTRON_RUN_AS_NODE: _electronRunAsNode, ...hostEnv } = process.env;
  let app: ElectronApplication | undefined;
  let userDataDir: string | undefined;

  try {
    userDataDir = await mkdtemp(join(tmpdir(), "comma-dev-protocol-e2e-"));
    app = await electron.launch({
      args: [
        electronMain,
        // The loopback HTTP/2 fixture uses an ephemeral self-signed certificate.
        "--ignore-certificate-errors",
        "--user-data-dir=" + userDataDir,
      ],
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

    await mainWindow.reload({ timeout: 15_000, waitUntil: "domcontentloaded" });

    await expect(mainWindow.locator("body")).toHaveAttribute("data-generation", "2");
    expect(stub.documentRequestCount).toBe(2);
    // The 32nd old request was already waiting inside the protocol handler.
    // Once an old body releases an asset permit it may reach upstream, but its
    // disconnected native consumer must immediately cancel the returned body.
    await expect.poll(() => stub.slowRequestCount).toBe(stalledAssetCount);
    await expect.poll(() => stub.activeSlowResponses).toBe(0);
  } finally {
    try {
      await app?.close();
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
  const certificate = await createTestCertificate();
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
  const close = async () => {
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
    await rm(certificate.directory, { force: true, recursive: true });
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

async function createTestCertificate() {
  const directory = await mkdtemp(join(tmpdir(), "comma-dev-protocol-cert-"));
  const certificatePath = join(directory, "certificate.pem");
  const configPath = join(directory, "openssl.cnf");
  const keyPath = join(directory, "private-key.pem");
  const config = [
    "[req]",
    "prompt = no",
    "distinguished_name = distinguished_name",
    "x509_extensions = extensions",
    "[distinguished_name]",
    "CN = 127.0.0.1",
    "[extensions]",
    "subjectAltName = @alt_names",
    "basicConstraints = critical,CA:TRUE",
    "keyUsage = critical,digitalSignature,keyEncipherment",
    "extendedKeyUsage = serverAuth",
    "[alt_names]",
    "IP.1 = 127.0.0.1",
    "DNS.1 = localhost",
  ].join("\n");

  try {
    await writeFile(configPath, config, "utf8");
    await execFileAsync("openssl", [
      "req",
      "-x509",
      "-newkey",
      "rsa:2048",
      "-nodes",
      "-keyout",
      keyPath,
      "-out",
      certificatePath,
      "-days",
      "1",
      "-sha256",
      "-config",
      configPath,
      "-extensions",
      "extensions",
    ]);
    return {
      cert: await readFile(certificatePath),
      directory,
      key: await readFile(keyPath),
    };
  } catch (error) {
    await rm(directory, { force: true, recursive: true });
    throw error;
  }
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

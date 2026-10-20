import { type ElectronApplication } from "@playwright/test";
import { build } from "esbuild";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { electron, expect, test } from "./electron-test";
import { startElectronTestServer } from "./electron-test-server";
import { closeElectronTestApp } from "./close-electron-test-app";

test("six HTTP/1 event streams leave transcriptions and ordinary API requests usable", async () => {
  const directory = await mkdtemp(join(tmpdir(), "comma-api-transport-"));
  let app: ElectronApplication | undefined;
  let activeStreams = 0;
  let streamsClosed!: () => void;
  const allStreamsClosed = new Promise<void>((notifyClosed) => {
    streamsClosed = notifyClosed;
  });
  const seen: {
    method: string;
    authorization: string | undefined;
    cookie: string | undefined;
  }[] = [];
  const frame =
    'event: transcription\ndata: {"status":"ready","result":{"transcript":"fixture","duration_seconds":1,"chunks":[]}}\n\n';
  const server = await startElectronTestServer((request, response) => {
    seen.push({
      method: request.method!,
      authorization: request.headers.authorization,
      cookie: request.headers.cookie,
    });
    if (request.url!.startsWith("/v1/comma/events/")) {
      activeStreams++;
      response.once("close", () => {
        activeStreams--;
        if (activeStreams === 0) streamsClosed();
      });
      response.writeHead(200, { "content-type": "text/event-stream" });
      response.write(": ready\n\n");
      return;
    }
    request.resume();
    request.once("end", () => {
      if (request.method === "POST") {
        response.writeHead(200, { "content-type": "text/event-stream" });
        response.end(frame);
      } else {
        response.writeHead(200, { "content-type": "application/json" });
        response.end('{"data":[]}');
      }
    });
  });
  try {
    await build({
      entryPoints: [resolve("apps/electron/e2e/fixtures/api-transport.ts")],
      outfile: join(directory, "main.cjs"),
      bundle: true,
      platform: "node",
      format: "cjs",
      external: ["electron"],
      tsconfig: resolve("tsconfig.test.json"),
    });
    app = await electron.launch({
      args: [
        join(directory, "main.cjs"),
        "--user-data-dir=" + join(directory, "profile"),
      ],
    });
    await app.evaluate(async (_electron, origin) => {
      const state = globalThis as unknown as {
        transportFixture(origin: string): Promise<{ open(): Promise<void> }>;
        transport: unknown;
      };
      const transport = await state.transportFixture(origin);
      state.transport = transport;
      await transport.open();
    }, server.origin);
    expect(activeStreams).toBe(6);
    const results = await app.evaluate(async () => {
      const { transport } = globalThis as unknown as {
        transport: { transcribe(): Promise<string[]>; read(): Promise<unknown> };
      };
      return Promise.all([transport.transcribe(), transport.read()]);
    });
    expect(results).toEqual([[frame, frame], { data: [] }]);
    expect(activeStreams).toBe(6);
    expect(seen).toHaveLength(9);
    expect(
      seen.every(
        ({ authorization, cookie }) =>
          authorization === "Bearer fixture-main-bearer" && cookie === undefined
      )
    ).toBe(true);
    await app.evaluate(async () => {
      await (
        globalThis as unknown as { transport: { close(): Promise<void> } }
      ).transport.close();
    });
    await allStreamsClosed;
    expect(activeStreams).toBe(0);
  } finally {
    if (app) await closeElectronTestApp(app);
    await server.close();
    await rm(directory, { force: true, recursive: true });
  }
});

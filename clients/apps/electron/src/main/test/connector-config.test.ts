import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { readConnectorConfig, writeConnectorConfig } from "../connector-config";

vi.mock("electron", () => ({
  app: {
    getName: () => "Comma Test",
    getPath: (name: string) => (name === "home" ? "/Users/test" : "/tmp/comma-test"),
  },
}));

let tempDir = "";

beforeEach(async () => {
  tempDir = await mkdtemp(join(tmpdir(), "comma-connector-config-"));
});

afterEach(async () => {
  await rm(tempDir, { recursive: true, force: true });
});

describe("writeConnectorConfig", () => {
  it("migrates an existing config to the managed local-file index root", async () => {
    const path = join(tempDir, "connector.json");
    await writeFile(
      path,
      JSON.stringify({
        connector: {
          connector_token: "connector-token",
          name: "legacy connector",
          reconnect: false,
          root: "/tmp/salix-root",
          server: "http://127.0.0.1:4200",
        },
        electron: { connector_binary_sha256: "abc123" },
      })
    );

    await expect(readConnectorConfig(path)).resolves.toEqual({
      connector: {
        connector_token: "connector-token",
        name: "legacy connector",
        reconnect: false,
        root: "/tmp/salix-root",
        server: "http://127.0.0.1:4200",
      },
      electron: {
        connector_binary_sha256: "abc123",
        local_file_index_root: join(tempDir, "local-file-index"),
        runtime_root: "/tmp/comma-test",
      },
    });
    expect(JSON.parse(await readFile(path, "utf8"))).toMatchObject({
      electron: {
        connector_binary_sha256: "abc123",
        local_file_index_root: join(tempDir, "local-file-index"),
      },
    });
  });

  it("writes the salix-connect config shape", async () => {
    const path = join(tempDir, "connector.json");

    await writeConnectorConfig(
      {
        server: " http://127.0.0.1:4200 ",
        token: " token ",
        alias: " laptop ",
      },
      path
    );

    await expect(readConnectorConfig(path)).resolves.toEqual({
      connector: {
        server: "http://127.0.0.1:4200",
        connector_token: "token",
        name: "Comma Test",
        alias: "laptop",
        root: "/Users/test",
        reconnect: true,
      },
      electron: {
        local_file_index_root: join(tempDir, "local-file-index"),
        runtime_root: "/tmp/comma-test",
      },
    });
  });

  it("writes managed comma config without persisting a salix token", async () => {
    const path = join(tempDir, "connector.json");

    await writeConnectorConfig(
      {
        commaApiBaseUrl: " http://127.0.0.1:4200 ",
        commaSessionToken: " comma_sess_test ",
        workspaceId: " wsp_1 ",
        alias: " laptop ",
      },
      path
    );

    await expect(readConnectorConfig(path)).resolves.toEqual({
      comma: {
        api_base_url: "http://127.0.0.1:4200",
        session_token: "comma_sess_test",
        workspace_id: "wsp_1",
      },
      connector: {
        name: "Comma Test",
        alias: "laptop",
        root: "/Users/test",
        reconnect: true,
      },
      electron: {
        local_file_index_root: join(tempDir, "local-file-index"),
        runtime_root: "/tmp/comma-test",
      },
    });
    expect(await readFile(path, "utf8")).not.toContain("connector_token");
  });

  it("rejects partial managed comma config", async () => {
    await expect(
      writeConnectorConfig(
        {
          commaApiBaseUrl: "http://127.0.0.1:4200",
          workspaceId: "wsp_1",
        },
        join(tempDir, "connector.json")
      )
    ).rejects.toThrow();
  });

  it("atomically writes a private JSON config", async () => {
    const path = join(tempDir, "connector.json");

    await writeConnectorConfig(
      {
        server: "http://127.0.0.1:4200",
        token: "connector-token",
        name: "dev machine",
        root: "/tmp/salix-root",
      },
      path,
      { connector_binary_sha256: "abc123" }
    );

    await expect(readConnectorConfig(path)).resolves.toEqual({
      connector: {
        server: "http://127.0.0.1:4200",
        connector_token: "connector-token",
        name: "dev machine",
        root: "/tmp/salix-root",
        reconnect: true,
      },
      electron: {
        connector_binary_sha256: "abc123",
        local_file_index_root: join(tempDir, "local-file-index"),
        runtime_root: "/tmp/comma-test",
      },
    });
    expect(await readFile(path, "utf8")).toContain('"connector_token"');

    if (process.platform !== "win32") {
      expect((await stat(path)).mode & 0o777).toBe(0o600);
    }
  });

  it("round-trips managed comma config", async () => {
    const path = join(tempDir, "connector.json");

    await writeConnectorConfig(
      {
        commaApiBaseUrl: "http://127.0.0.1:4200",
        commaSessionToken: "comma_sess_test",
        workspaceId: "wsp_1",
        name: "dev machine",
        root: "/tmp/salix-root",
      },
      path
    );

    await expect(readConnectorConfig(path)).resolves.toEqual({
      comma: {
        api_base_url: "http://127.0.0.1:4200",
        session_token: "comma_sess_test",
        workspace_id: "wsp_1",
      },
      connector: {
        name: "dev machine",
        root: "/tmp/salix-root",
        reconnect: true,
      },
      electron: {
        local_file_index_root: join(tempDir, "local-file-index"),
        runtime_root: "/tmp/comma-test",
      },
    });
    expect(await readFile(path, "utf8")).not.toContain("connector_token");
  });
});

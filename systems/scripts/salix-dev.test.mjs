import assert from "node:assert/strict";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";

import {
  assertHostPortsAvailable,
  deriveSandbox,
  normalizeId,
  prepareConfig,
  renderConfig,
} from "./salix-dev.mjs";

describe("isolated Salix development sandbox", () => {
  it("derives stable, distinct project identities and port pairs per worktree", () => {
    const first = deriveSandbox({ repoRoot: "/tmp/worktrees/feature-a/Comma" });
    const repeated = deriveSandbox({ repoRoot: "/tmp/worktrees/feature-a/Comma" });
    const second = deriveSandbox({ repoRoot: "/tmp/worktrees/feature-b/Comma" });

    assert.deepEqual(first, repeated);
    assert.notEqual(first.project, second.project);
    assert.notEqual(first.httpPort, second.httpPort);
    assert.notEqual(first.transferPort, second.transferPort);
    assert.match(first.project, /^comma-salix-feature-a-comma-[a-f0-9]{6}$/);
    assert.notEqual(first.project, "comma-salix-local");
  });

  it("honors explicit names and ports while rejecting invalid input", () => {
    const sandbox = deriveSandbox({
      repoRoot: "/tmp/worktrees/Comma",
      env: {
        SALIX_DEV_ID: "Router Memory",
        SALIX_DEV_HTTP_PORT: "25001",
        SALIX_DEV_TRANSFER_PORT: "45001",
      },
    });

    assert.equal(sandbox.id, "router-memory");
    assert.equal(sandbox.httpPort, 25001);
    assert.equal(sandbox.transferPort, 45001);
    assert.throws(
      () =>
        deriveSandbox({
          repoRoot: "/tmp/worktrees/Comma",
          env: { SALIX_DEV_HTTP_PORT: "70000" },
        }),
      /SALIX_DEV_HTTP_PORT/,
    );
    assert.throws(() => normalizeId("---"), /at least one letter or number/);
  });

  it("keeps dependencies on their Compose DNS names and advertises mapped transfer port", () => {
    const sandbox = deriveSandbox({
      repoRoot: "/tmp/worktrees/Comma",
      env: { SALIX_DEV_HTTP_PORT: "25002", SALIX_DEV_TRANSFER_PORT: "45002" },
    });
    const config = renderConfig(sandbox);

    assert.equal(config.storage.endpoint, "http://minio:9000");
    assert.equal(config.salix.database.url, "ecto://postgres:postgres@postgres:5432/billing_core_dev");
    assert.equal(config.clickhouse.url, "http://clickhouse:8123");
    assert.equal(config.llm.default_template.provider_config.base_url, "http://llm-mock:43123");
    assert.equal(config.web.port, 4000);
    assert.equal(config.web.api_base_url, "http://127.0.0.1:25002");
    assert.equal(config.transfer.port, 4400);
    assert.equal(config.transfer.advertise_port, 45002);
  });

  it(
    "keeps local credentials private while allowing release UID 10001 to read the mount",
    () => {
      const root = mkdtempSync(path.join(os.tmpdir(), "salix-dev-config-"));

      try {
        const sandbox = deriveSandbox({ repoRoot: root });
        prepareConfig(sandbox);

        const directory = statSync(sandbox.stateDir);
        const config = statSync(sandbox.configPath);

        assert.equal(directory.mode & 0o777, 0o700);
        assert.equal(config.mode & 0o777, 0o644);
        assert.equal(posixCanRead(config, 10_001, 10_001), true);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    },
  );

  it("rejects an occupied host port before Compose can create containers", async () => {
    const server = net.createServer();
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen({ host: "127.0.0.1", port: 0 }, resolve);
    });

    try {
      const address = server.address();
      assert.equal(typeof address, "object");
      await assert.rejects(
        assertHostPortsAvailable({ httpPort: address.port, transferPort: 0 }),
        /already in use/,
      );
    } finally {
      await new Promise((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      );
    }
  });
});

function posixCanRead(stat, uid, gid) {
  if (uid === 0) return true;
  if (uid === stat.uid) return Boolean(stat.mode & 0o400);
  if (gid === stat.gid) return Boolean(stat.mode & 0o040);
  return Boolean(stat.mode & 0o004);
}

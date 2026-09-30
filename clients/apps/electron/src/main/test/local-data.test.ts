import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, describe, expect, it } from "vitest";
import { FileStore } from "../modules/local-data";
import {
  LOCAL_DATA_MIGRATIONS,
  LOCAL_DATA_SCHEMA_VERSION,
  LocalDataService,
  applyLocalDataMigrations,
  type LocalDataMigration,
} from "../../utility/local-data-service";

const tempDirs: string[] = [];
const TEST_AUDIENCE = "https://api.comma.test";

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { force: true, recursive: true });
  }
});

describe("LocalDataService", () => {
  it("does not expose a generic local_kv JSON API", () => {
    const databasePath = tempDatabasePath();
    const service = LocalDataService.open({ databasePath });

    try {
      expect("getJson" in service).toBe(false);
      expect("setJson" in service).toBe(false);
    } finally {
      service.close();
    }
  });

  it("migrates an empty SQLite database to the latest local data schema", () => {
    const databasePath = tempDatabasePath();
    const service = LocalDataService.open({
      databasePath,
    });

    try {
      expect(service.schemaVersion()).toBe(LOCAL_DATA_SCHEMA_VERSION);
    } finally {
      service.close();
    }

    expect(databaseObjectExists(databasePath, "table", "local_kv")).toBe(true);
    expect(databaseObjectExists(databasePath, "index", "idx_local_kv_updated_at")).toBe(
      true
    );
    expect(databaseObjectExists(databasePath, "table", "local_blob_refs")).toBe(true);
    expect(databaseObjectExists(databasePath, "table", "product_workspaces")).toBe(
      true
    );
    expect(databaseObjectExists(databasePath, "table", "product_conversations")).toBe(
      true
    );
  });

  it("migrates a v1 database forward to the latest local data schema", () => {
    const databasePath = tempDatabasePath();
    const v1 = LocalDataService.open({
      databasePath,
      migrations: LOCAL_DATA_MIGRATIONS.slice(0, 1),
    });

    try {
      expect(v1.schemaVersion()).toBe(1);
    } finally {
      v1.close();
    }

    const latest = LocalDataService.open({ databasePath });

    try {
      expect(latest.schemaVersion()).toBe(LOCAL_DATA_SCHEMA_VERSION);
      expect(databaseObjectExists(databasePath, "table", "local_blob_refs")).toBe(true);
      expect(
        databaseObjectExists(databasePath, "index", "idx_local_blob_refs_blob_id")
      ).toBe(true);
      expect(databaseObjectExists(databasePath, "table", "product_workspaces")).toBe(
        true
      );
      expect(databaseObjectExists(databasePath, "table", "product_conversations")).toBe(
        true
      );
      expect(
        databaseObjectExists(
          databasePath,
          "index",
          "idx_product_conversations_partition_updated_at"
        )
      ).toBe(true);
      expect(
        databaseObjectExists(
          databasePath,
          "index",
          "idx_product_conversations_partition_workspace_updated_at"
        )
      ).toBe(true);
      expect(
        databaseObjectExists(databasePath, "table", "comma_schema_migrations")
      ).toBe(false);
    } finally {
      latest.close();
    }
  });

  it("rebuilds the conversation cache with strict canonical kinds and no event cursor", () => {
    const databasePath = tempDatabasePath();
    const v6 = LocalDataService.open({
      databasePath,
      migrations: LOCAL_DATA_MIGRATIONS.slice(0, 6),
    });

    v6.close();

    const legacyDatabase = new DatabaseSync(databasePath);
    try {
      legacyDatabase
        .prepare(
          `
            INSERT INTO product_workspaces (principal_id, id, name, raw_json, updated_at)
            VALUES (?, ?, ?, ?, ?)
          `
        )
        .run("principal-a", "wsp_1", "Workspace", "{}", 1);

      legacyDatabase
        .prepare(
          `
            INSERT INTO product_conversations (
              principal_id, workspace_id, id, title, status,
              created_at, updated_at, last_event_id, raw_json, synced_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          `
        )
        .run("principal-a", "wsp_1", "cnv_legacy", "Legacy", "idle", 1, 1, 0, "{}", 1);
    } finally {
      legacyDatabase.close();
    }

    const latest = LocalDataService.open({ databasePath });
    try {
      expect(latest.schemaVersion()).toBe(LOCAL_DATA_SCHEMA_VERSION);
      expect(
        latest.listProductInboxItems({
          audience: "https://api.comma.test",
          principalId: "principal-a",
        })
      ).toEqual([]);
    } finally {
      latest.close();
    }

    const strictDatabase = new DatabaseSync(databasePath);
    try {
      strictDatabase
        .prepare(
          `
            INSERT INTO product_workspaces (
              principal_id, audience, id, group_id, name, raw_json, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
          `
        )
        .run(
          "principal-a",
          "https://api.comma.test",
          "wsp_1",
          "grp_1",
          "Workspace",
          "{}",
          1
        );
      const insert = strictDatabase.prepare(`
        INSERT INTO product_conversations (
          principal_id, audience, workspace_id, group_id, id, title, status, kind,
          created_at, updated_at, raw_json, synced_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);

      expect(() =>
        insert.run(
          "principal-a",
          "https://api.comma.test",
          "wsp_1",
          "grp_1",
          "cnv_invalid",
          "Invalid",
          "idle",
          "assistant",
          1,
          1,
          "{}",
          1
        )
      ).toThrow();

      expect(() =>
        strictDatabase.exec(`
          INSERT INTO product_conversations (
            principal_id, audience, workspace_id, group_id, id, title, status,
            created_at, updated_at, raw_json, synced_at
          ) VALUES (
            'principal-a', 'https://api.comma.test', 'wsp_1', 'grp_1',
            'cnv_missing', 'Missing', 'idle',
            1, 1, '{}', 1
          );
        `)
      ).toThrow();

      const columns = strictDatabase
        .prepare("PRAGMA table_info(product_conversations)")
        .all() as Array<{ name: string }>;
      expect(columns.map((column) => column.name)).not.toContain("last_event_id");
    } finally {
      strictDatabase.close();
    }
  });

  it("rebuilds and clears a legacy v8 cache before adding audience partitions", () => {
    const databasePath = tempDatabasePath();
    const v8 = LocalDataService.open({
      databasePath,
      migrations: LOCAL_DATA_MIGRATIONS.slice(0, 8),
    });
    v8.close();

    const legacyDatabase = new DatabaseSync(databasePath);
    try {
      legacyDatabase.exec(`
        INSERT INTO product_workspaces (
          principal_id, id, name, raw_json, updated_at
        ) VALUES (
          'principal-a', 'wsp_legacy', 'Legacy workspace', '{}', 1
        );

        INSERT INTO product_conversations (
          principal_id, workspace_id, id, title, status, kind,
          created_at, updated_at, raw_json, synced_at
        ) VALUES (
          'principal-a', 'wsp_legacy', 'cnv_legacy', 'Legacy', 'idle',
          'user_chat', 1, 1, '{}', 1
        );
      `);
    } finally {
      legacyDatabase.close();
    }

    const latest = LocalDataService.open({ databasePath });
    try {
      expect(latest.schemaVersion()).toBe(LOCAL_DATA_SCHEMA_VERSION);
      expect(
        latest.listProductInboxItems({
          audience: "https://api-a.comma.test",
          principalId: "principal-a",
        })
      ).toEqual([]);
      expect(
        latest.listProductWorkspaces({
          audience: "https://api-b.comma.test",
          principalId: "principal-a",
        })
      ).toEqual([]);
    } finally {
      latest.close();
    }

    const database = new DatabaseSync(databasePath);
    try {
      const workspaceColumns = database
        .prepare("PRAGMA table_info(product_workspaces)")
        .all() as Array<{ name: string }>;
      const conversationColumns = database
        .prepare("PRAGMA table_info(product_conversations)")
        .all() as Array<{ name: string }>;
      expect(workspaceColumns.map((column) => column.name)).toContain("audience");
      expect(workspaceColumns.map((column) => column.name)).toContain("group_id");
      expect(conversationColumns.map((column) => column.name)).toContain("audience");
      expect(conversationColumns.map((column) => column.name)).toContain("group_id");
    } finally {
      database.close();
    }
  });

  it("stores Salix conversations as typed local inbox rows sorted by activity", () => {
    const databasePath = tempDatabasePath();
    const service = LocalDataService.open({
      databasePath,
      now: () => 1_700_000_000_000,
    });

    try {
      service.upsertProductWorkspace({
        audience: TEST_AUDIENCE,
        groupId: "grp_1",
        id: "wsp_1",
        name: "Main workspace",
        principalId: "email:peng@example.com",
        raw: { group_id: "grp_1", id: "wsp_1", name: "Main workspace" },
      });
      service.upsertProductConversation({
        audience: TEST_AUDIENCE,
        createdAt: 10,
        groupId: "grp_1",
        id: "cnv_old",
        kind: "user_chat",
        principalId: "email:peng@example.com",
        raw: {
          id: "cnv_old",
          status: "idle",
          title: "Old thread",
          group_id: "grp_1",
        },
        status: "idle",
        title: "Old thread",
        updatedAt: 20,
        workspaceId: "wsp_1",
      });
      service.upsertProductConversation({
        audience: TEST_AUDIENCE,
        createdAt: 30,
        groupId: "grp_1",
        id: "cnv_new",
        kind: "user_chat",
        principalId: "email:peng@example.com",
        raw: {
          id: "cnv_new",
          status: "waiting",
          title: "New thread",
          group_id: "grp_1",
        },
        status: "waiting",
        title: "New thread",
        updatedAt: 40,
        workspaceId: "wsp_1",
      });

      expect(
        service.listProductInboxItems({
          audience: TEST_AUDIENCE,
          limit: 10,
          principalId: "email:peng@example.com",
        })
      ).toEqual([
        {
          audience: TEST_AUDIENCE,
          conversationId: "cnv_new",
          raw: {
            id: "cnv_new",
            status: "waiting",
            title: "New thread",
            group_id: "grp_1",
          },
          groupId: "grp_1",
          id: "grp_1:cnv_new",
          kind: "user_chat",
          source: "salix.conversation",
          status: "waiting",
          title: "New thread",
          updatedAt: 40,
          workspaceId: "wsp_1",
          workspaceName: "Main workspace",
        },
        {
          audience: TEST_AUDIENCE,
          conversationId: "cnv_old",
          raw: {
            id: "cnv_old",
            status: "idle",
            title: "Old thread",
            group_id: "grp_1",
          },
          groupId: "grp_1",
          id: "grp_1:cnv_old",
          kind: "user_chat",
          source: "salix.conversation",
          status: "idle",
          title: "Old thread",
          updatedAt: 20,
          workspaceId: "wsp_1",
          workspaceName: "Main workspace",
        },
      ]);
    } finally {
      service.close();
    }
  });

  it("preserves existing Salix conversation created_at when a resync omits or changes it", () => {
    const databasePath = tempDatabasePath();
    const service = LocalDataService.open({
      databasePath,
      now: () => 1_700_000_000_000,
    });

    try {
      service.upsertProductWorkspace({
        audience: TEST_AUDIENCE,
        groupId: "grp_1",
        id: "wsp_1",
        name: "Main workspace",
        principalId: "email:peng@example.com",
        raw: { group_id: "grp_1", id: "wsp_1", name: "Main workspace" },
      });
      service.upsertProductConversation({
        audience: TEST_AUDIENCE,
        createdAt: 10,
        groupId: "grp_1",
        id: "cnv_1",
        kind: "user_chat",
        principalId: "email:peng@example.com",
        raw: { group_id: "grp_1", id: "cnv_1" },
        status: "waiting",
        title: "Original thread",
        updatedAt: 20,
        workspaceId: "wsp_1",
      });
      service.upsertProductConversation({
        audience: TEST_AUDIENCE,
        createdAt: 99,
        groupId: "grp_1",
        id: "cnv_1",
        kind: "user_chat",
        principalId: "email:peng@example.com",
        raw: { group_id: "grp_1", id: "cnv_1" },
        status: "idle",
        title: "Resynced thread",
        updatedAt: 30,
        workspaceId: "wsp_1",
      });
    } finally {
      service.close();
    }

    expect(
      readProductConversationCreatedAt(
        databasePath,
        "email:peng@example.com",
        TEST_AUDIENCE,
        "wsp_1",
        "cnv_1"
      )
    ).toBe(10);
  });

  it("reconciles absent product workspaces and cascades their conversations", () => {
    const databasePath = tempDatabasePath();
    const service = LocalDataService.open({
      databasePath,
      now: () => 1_700_000_000_000,
    });

    try {
      service.upsertProductWorkspace({
        audience: TEST_AUDIENCE,
        groupId: "grp_revoked",
        id: "wsp_revoked",
        name: "Revoked",
        principalId: "principal-a",
        raw: { group_id: "grp_revoked", id: "wsp_revoked", name: "Revoked" },
      });
      service.upsertProductConversation({
        audience: TEST_AUDIENCE,
        groupId: "grp_revoked",
        id: "cnv_revoked",
        kind: "user_chat",
        principalId: "principal-a",
        raw: { group_id: "grp_revoked", id: "cnv_revoked" },
        status: "idle",
        title: "Revoked title",
        updatedAt: 20,
        workspaceId: "wsp_revoked",
      });

      service.applyProductInboxSync({
        audience: TEST_AUDIENCE,
        principalId: "principal-a",
        session: testSession(),
        workspaces: { items: [], mode: "replace" },
      });

      expect(
        service.listProductInboxItems({
          audience: TEST_AUDIENCE,
          limit: 10,
          principalId: "principal-a",
        })
      ).toEqual([]);
      expect(
        service.listProductWorkspaces({
          audience: TEST_AUDIENCE,
          principalId: "principal-a",
        })
      ).toEqual([]);
    } finally {
      service.close();
    }
  });

  it("applies workspace and conversation projection writes atomically", () => {
    const service = LocalDataService.open({
      databasePath: tempDatabasePath(),
      now: () => 1_700_000_000_000,
    });

    try {
      service.applyProductInboxSync({
        audience: TEST_AUDIENCE,
        conversations: {
          items: [
            {
              audience: TEST_AUDIENCE,
              groupId: "grp_1",
              id: "cnv_1",
              kind: "agent_task",
              principalId: "principal-a",
              raw: { group_id: "grp_1", id: "cnv_1" },
              status: "working",
              title: "Original task",
              updatedAt: 20,
              workspaceId: "wsp_1",
            },
          ],
          mode: "replace",
          workspaceId: "wsp_1",
        },
        principalId: "principal-a",
        session: testSession(),
        workspaces: {
          items: [
            {
              audience: TEST_AUDIENCE,
              groupId: "grp_1",
              id: "wsp_1",
              name: "Original workspace",
              principalId: "principal-a",
              raw: {
                group_id: "grp_1",
                id: "wsp_1",
                name: "Original workspace",
              },
            },
          ],
          mode: "replace",
        },
      });

      expect(() =>
        service.applyProductInboxSync({
          audience: TEST_AUDIENCE,
          conversations: {
            items: [
              {
                audience: TEST_AUDIENCE,
                groupId: "grp_1",
                id: "cnv_invalid",
                kind: "invalid" as "user_chat",
                principalId: "principal-a",
                raw: { group_id: "grp_1", id: "cnv_invalid" },
                status: "working",
                title: "Invalid task",
                updatedAt: 30,
                workspaceId: "wsp_1",
              },
            ],
            mode: "replace",
            workspaceId: "wsp_1",
          },
          principalId: "principal-a",
          session: testSession(),
          workspaces: {
            items: [
              {
                audience: TEST_AUDIENCE,
                groupId: "grp_1",
                id: "wsp_1",
                name: "Must roll back",
                principalId: "principal-a",
                raw: { group_id: "grp_1", id: "wsp_1", name: "Must roll back" },
              },
            ],
            mode: "replace",
          },
        })
      ).toThrow();

      expect(
        service.listProductWorkspaces({
          audience: TEST_AUDIENCE,
          principalId: "principal-a",
        })
      ).toEqual([expect.objectContaining({ id: "wsp_1", name: "Original workspace" })]);
      expect(
        service.listProductInboxItems({
          audience: TEST_AUDIENCE,
          principalId: "principal-a",
          workspaceId: "wsp_1",
        })
      ).toEqual([
        expect.objectContaining({
          conversationId: "cnv_1",
          title: "Original task",
        }),
      ]);
    } finally {
      service.close();
    }
  });

  it("preserves cursor tails for merge writes and deletes them only for replace", () => {
    const service = LocalDataService.open({
      databasePath: tempDatabasePath(),
      now: () => 1_700_000_000_000,
    });
    const workspace = {
      audience: TEST_AUDIENCE,
      groupId: "grp_1",
      id: "wsp_1",
      name: "Main workspace",
      principalId: "principal-a",
      raw: { group_id: "grp_1", id: "wsp_1", name: "Main workspace" },
    };
    const conversation = (id: string, updatedAt: number) => ({
      audience: TEST_AUDIENCE,
      groupId: "grp_1",
      id,
      kind: "agent_task" as const,
      principalId: "principal-a",
      raw: { group_id: "grp_1", id },
      status: "working",
      title: id,
      updatedAt,
      workspaceId: "wsp_1",
    });

    try {
      service.applyProductInboxSync({
        audience: TEST_AUDIENCE,
        conversations: {
          items: [conversation("cnv_first", 20), conversation("cnv_tail", 10)],
          mode: "replace",
          workspaceId: "wsp_1",
        },
        principalId: "principal-a",
        session: testSession(),
        workspaces: { items: [workspace], mode: "replace" },
      });
      service.applyProductInboxSync({
        audience: TEST_AUDIENCE,
        conversations: {
          items: [conversation("cnv_first", 30)],
          mode: "merge",
          workspaceId: "wsp_1",
        },
        principalId: "principal-a",
        session: testSession(),
        workspaces: { items: [workspace], mode: "merge" },
      });

      expect(
        service
          .listProductInboxItems({
            audience: TEST_AUDIENCE,
            principalId: "principal-a",
            workspaceId: "wsp_1",
          })
          .map((item) => item.conversationId)
      ).toEqual(["cnv_first", "cnv_tail"]);

      service.applyProductInboxSync({
        audience: TEST_AUDIENCE,
        conversations: {
          items: [conversation("cnv_first", 40)],
          mode: "replace",
          workspaceId: "wsp_1",
        },
        principalId: "principal-a",
        session: testSession(),
        workspaces: { items: [workspace], mode: "merge" },
      });

      expect(
        service
          .listProductInboxItems({
            audience: TEST_AUDIENCE,
            principalId: "principal-a",
            workspaceId: "wsp_1",
          })
          .map((item) => item.conversationId)
      ).toEqual(["cnv_first"]);
    } finally {
      service.close();
    }
  });

  it("isolates identical principal, workspace, and conversation ids by audience", () => {
    const service = LocalDataService.open({
      databasePath: tempDatabasePath(),
      now: () => 1_700_000_000_000,
    });
    const writePartition = (audience: string, label: string) =>
      service.applyProductInboxSync({
        audience,
        conversations: {
          items: [
            {
              audience,
              groupId: "grp_1",
              id: "cnv_1",
              kind: "user_chat",
              principalId: "principal-a",
              raw: { audience, group_id: "grp_1", id: "cnv_1" },
              status: "idle",
              title: `${label} conversation`,
              updatedAt: 20,
              workspaceId: "wsp_1",
            },
          ],
          mode: "replace",
          workspaceId: "wsp_1",
        },
        principalId: "principal-a",
        session: testSession(audience),
        workspaces: {
          items: [
            {
              audience,
              groupId: "grp_1",
              id: "wsp_1",
              name: `${label} workspace`,
              principalId: "principal-a",
              raw: { audience, group_id: "grp_1", id: "wsp_1" },
            },
          ],
          mode: "replace",
        },
      });

    try {
      writePartition("https://api-a.comma.test", "Audience A");
      writePartition("https://api-b.comma.test", "Audience B");

      expect(
        service.listProductInboxItems({
          audience: "https://api-a.comma.test",
          principalId: "principal-a",
        })
      ).toEqual([
        expect.objectContaining({
          audience: "https://api-a.comma.test",
          title: "Audience A conversation",
          workspaceName: "Audience A workspace",
        }),
      ]);
      expect(
        service.listProductInboxItems({
          audience: "https://api-b.comma.test",
          principalId: "principal-a",
        })
      ).toEqual([
        expect.objectContaining({
          audience: "https://api-b.comma.test",
          title: "Audience B conversation",
          workspaceName: "Audience B workspace",
        }),
      ]);

      service.applyProductInboxSync({
        audience: "https://api-a.comma.test",
        principalId: "principal-a",
        session: testSession("https://api-a.comma.test"),
        workspaces: { items: [], mode: "replace" },
      });

      expect(
        service.listProductInboxItems({
          audience: "https://api-a.comma.test",
          principalId: "principal-a",
        })
      ).toEqual([]);
      expect(
        service.listProductInboxItems({
          audience: "https://api-b.comma.test",
          principalId: "principal-a",
        })
      ).toHaveLength(1);
    } finally {
      service.close();
    }
  });

  it("rolls back failed migrations without leaving partial schema", () => {
    const databasePath = tempDatabasePath();
    const database = new DatabaseSync(databasePath);
    const failingMigration: LocalDataMigration = {
      name: "fail after creating transient table",
      version: LOCAL_DATA_SCHEMA_VERSION + 1,
      up(migrationDatabase) {
        migrationDatabase.exec("CREATE TABLE transient_failure_marker (id INTEGER);");
        throw new Error("boom");
      },
    };

    try {
      applyLocalDataMigrations(database);

      expect(() =>
        applyLocalDataMigrations(database, [...LOCAL_DATA_MIGRATIONS, failingMigration])
      ).toThrow("boom");

      expect(schemaVersion(database)).toBe(LOCAL_DATA_SCHEMA_VERSION);
      expect(databaseObjectExists(database, "table", "transient_failure_marker")).toBe(
        false
      );
    } finally {
      database.close();
    }
  });
});

describe("FileStore", () => {
  it("does not expose blob write, garbage collection, or quota APIs", () => {
    const { fileStore, localData } = openLocalDataWithFileStore();

    try {
      expect("putBytes" in fileStore).toBe(false);
      expect("readBytes" in fileStore).toBe(false);
      expect("collectGarbage" in fileStore).toBe(false);
      expect("blobPathForTest" in fileStore).toBe(false);
      expect("addBlobReference" in localData).toBe(false);
    } finally {
      localData.close();
    }
  });

  it("reads content-addressed blob diagnostics from disk", async () => {
    const { databasePath, fileStore, localData, rootDir } =
      openLocalDataWithFileStore();
    const existingHash = "a".repeat(64);
    const secondHash = "b".repeat(64);
    const missingHash = "c".repeat(64);
    const existingBlobId = `sha256:${existingHash}`;
    const missingBlobId = `sha256:${missingHash}`;

    try {
      writeContentAddressedBlob(rootDir, existingHash, "hello");
      writeContentAddressedBlob(rootDir, secondHash, "!");
      insertBlobReference(databasePath, existingBlobId);
      insertBlobReference(databasePath, missingBlobId);

      expect(fileStore.blobCount()).toBe(2);
      expect(fileStore.totalBytes()).toBe(6);
      await expect(fileStore.findMissingReferencedBlobs()).resolves.toEqual([
        missingBlobId,
      ]);
    } finally {
      localData.close();
    }
  });
});

function tempDatabasePath() {
  const dir = mkdtempSync(join(tmpdir(), "comma-local-data-"));
  tempDirs.push(dir);
  return join(dir, "comma.sqlite");
}

function openLocalDataWithFileStore() {
  const dir = mkdtempSync(join(tmpdir(), "comma-file-store-"));
  tempDirs.push(dir);
  const databasePath = join(dir, "comma.sqlite");
  const rootDir = join(dir, "blobs");
  const localData = LocalDataService.open({
    databasePath,
  });
  const fileStore = FileStore.open({
    localData,
    rootDir,
  });

  return { databasePath, fileStore, localData, rootDir };
}

function insertBlobReference(databasePath: string, blobId: string) {
  const database = new DatabaseSync(databasePath);

  try {
    database
      .prepare(
        `
          INSERT INTO local_blob_refs (owner_kind, owner_id, blob_id, created_at)
          VALUES (?, ?, ?, ?)
        `
      )
      .run("message", blobId, blobId, 1);
  } finally {
    database.close();
  }
}

function writeContentAddressedBlob(
  rootDir: string,
  contentHash: string,
  contents: string
) {
  const prefixDir = join(rootDir, contentHash.slice(0, 2));
  mkdirSync(prefixDir, { recursive: true });
  writeFileSync(join(prefixDir, contentHash), contents);
}

function readProductConversationCreatedAt(
  databasePath: string,
  principalId: string,
  audience: string,
  workspaceId: string,
  conversationId: string
) {
  const database = new DatabaseSync(databasePath);

  try {
    const row = database
      .prepare(
        `
          SELECT created_at
          FROM product_conversations
          WHERE principal_id = ? AND audience = ? AND workspace_id = ? AND id = ?
        `
      )
      .get(principalId, audience, workspaceId, conversationId) as {
      created_at?: number | null;
    };

    return row.created_at;
  } finally {
    database.close();
  }
}

function databaseObjectExists(
  databaseOrPath: DatabaseSync | string,
  type: "index" | "table",
  name: string
) {
  const inspectedDatabase =
    typeof databaseOrPath === "string"
      ? new DatabaseSync(databaseOrPath)
      : databaseOrPath;

  try {
    const row = inspectedDatabase
      .prepare(
        `
          SELECT name
          FROM sqlite_master
          WHERE type = ? AND name = ?
        `
      )
      .get(type, name);

    return Boolean(row);
  } finally {
    if (typeof databaseOrPath === "string") {
      inspectedDatabase.close();
    }
  }
}

function schemaVersion(database: DatabaseSync) {
  const row = database.prepare("PRAGMA user_version").get() as {
    user_version?: number;
  };

  return row.user_version ?? 0;
}

function testSession(audience = TEST_AUDIENCE) {
  return {
    audience,
    authorityInstanceId: "authority-test",
    generation: 1,
    sessionId: "session-test",
  };
}

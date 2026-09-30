import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type {
  LocalDataJsonValue,
  LocalProductInboxItem,
  ProductConversationKind,
  ProductInboxCacheApplyInput,
} from "../shared/local-data";
import {
  assertNormalizedLocalDataAudience,
  assertProductInboxCacheApplyInput,
} from "../shared/local-data";

export type {
  LocalProductInboxItem,
  ProductConversationKind,
  ProductInboxCacheApplyInput,
  ProductInboxCacheWriteMode,
} from "../shared/local-data";

export { LOCAL_DATA_SCHEMA_VERSION } from "../shared/local-data";

export interface LocalDataMigration {
  name: string;
  up(database: DatabaseSync): void;
  version: number;
}

export interface ProductWorkspaceInput {
  audience: string;
  groupId: string;
  id: string;
  name: string;
  principalId: string;
  raw: unknown;
}

export interface ProductConversationInput {
  audience: string;
  groupId: string;
  id: string;
  principalId: string;
  workspaceId: string;
  title: string;
  status: string;
  kind: ProductConversationKind;
  freshness?: "fresh" | "stale" | "unknown" | undefined;
  raw: unknown;
  createdAt?: number | undefined;
  updatedAt?: number | undefined;
}

export const LOCAL_DATA_MIGRATIONS: readonly LocalDataMigration[] = [
  {
    name: "create local metadata store",
    version: 1,
    up(database) {
      database.exec(`
        CREATE TABLE local_kv (
          namespace TEXT NOT NULL,
          key TEXT NOT NULL,
          value_json TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (namespace, key)
        );

        CREATE INDEX idx_local_kv_updated_at
          ON local_kv(updated_at);
      `);
    },
  },
  {
    name: "create blob reference metadata",
    version: 2,
    up(database) {
      database.exec(`
        CREATE TABLE local_blob_refs (
          owner_kind TEXT NOT NULL,
          owner_id TEXT NOT NULL,
          blob_id TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          PRIMARY KEY (owner_kind, owner_id, blob_id)
        );

        CREATE INDEX idx_local_blob_refs_blob_id
          ON local_blob_refs(blob_id);
      `);
    },
  },
  {
    name: "create product workspace and conversation cache",
    version: 3,
    up(database) {
      database.exec(`
        CREATE TABLE product_workspaces (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          raw_json TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        );

        CREATE TABLE product_conversations (
          workspace_id TEXT NOT NULL,
          id TEXT NOT NULL,
          title TEXT NOT NULL,
          status TEXT NOT NULL,
          created_at INTEGER,
          updated_at INTEGER NOT NULL,
          last_event_id INTEGER,
          raw_json TEXT NOT NULL,
          synced_at INTEGER NOT NULL,
          PRIMARY KEY (workspace_id, id),
          FOREIGN KEY (workspace_id)
            REFERENCES product_workspaces(id)
            ON DELETE CASCADE
        );

        CREATE INDEX idx_product_conversations_updated_at
          ON product_conversations(updated_at DESC);
      `);
    },
  },
  {
    name: "partition product cache by principal",
    version: 4,
    up(database) {
      database.exec(`
        DROP TABLE IF EXISTS product_conversations;
        DROP TABLE IF EXISTS product_workspaces;

        CREATE TABLE product_workspaces (
          principal_id TEXT NOT NULL,
          id TEXT NOT NULL,
          name TEXT NOT NULL,
          raw_json TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (principal_id, id)
        );

        CREATE TABLE product_conversations (
          principal_id TEXT NOT NULL,
          workspace_id TEXT NOT NULL,
          id TEXT NOT NULL,
          title TEXT NOT NULL,
          status TEXT NOT NULL,
          created_at INTEGER,
          updated_at INTEGER NOT NULL,
          last_event_id INTEGER,
          raw_json TEXT NOT NULL,
          synced_at INTEGER NOT NULL,
          PRIMARY KEY (principal_id, workspace_id, id),
          FOREIGN KEY (principal_id, workspace_id)
            REFERENCES product_workspaces(principal_id, id)
            ON DELETE CASCADE
        );

        CREATE INDEX idx_product_conversations_principal_updated_at
          ON product_conversations(principal_id, updated_at DESC);
      `);
    },
  },
  {
    name: "index product conversations by principal and workspace",
    version: 5,
    up(database) {
      database.exec(`
        CREATE INDEX idx_product_conversations_principal_workspace_updated_at
          ON product_conversations(principal_id, workspace_id, updated_at DESC);
      `);
    },
  },
  {
    name: "cache conversation kind and freshness",
    version: 6,
    up(database) {
      database.exec(`
        ALTER TABLE product_conversations
          ADD COLUMN kind TEXT NOT NULL DEFAULT 'user_chat';

        ALTER TABLE product_conversations
          ADD COLUMN freshness_state TEXT;
      `);
    },
  },
  {
    name: "enforce canonical conversation kinds",
    version: 7,
    up(database) {
      database.exec(`
        CREATE TABLE product_conversations_v7 (
          principal_id TEXT NOT NULL,
          workspace_id TEXT NOT NULL,
          id TEXT NOT NULL,
          title TEXT NOT NULL,
          status TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('user_chat', 'agent_task')),
          freshness_state TEXT,
          created_at INTEGER,
          updated_at INTEGER NOT NULL,
          last_event_id INTEGER,
          raw_json TEXT NOT NULL,
          synced_at INTEGER NOT NULL,
          PRIMARY KEY (principal_id, workspace_id, id),
          FOREIGN KEY (principal_id, workspace_id)
            REFERENCES product_workspaces(principal_id, id)
            ON DELETE CASCADE
        );

        DROP TABLE product_conversations;
        ALTER TABLE product_conversations_v7 RENAME TO product_conversations;

        CREATE INDEX idx_product_conversations_principal_updated_at
          ON product_conversations(principal_id, updated_at DESC);

        CREATE INDEX idx_product_conversations_principal_workspace_updated_at
          ON product_conversations(principal_id, workspace_id, updated_at DESC);
      `);
    },
  },
  {
    name: "remove retired conversation event cursor cache",
    version: 8,
    up(database) {
      database.exec(`
        DROP TABLE product_conversations;

        CREATE TABLE product_conversations (
          principal_id TEXT NOT NULL,
          workspace_id TEXT NOT NULL,
          id TEXT NOT NULL,
          title TEXT NOT NULL,
          status TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('user_chat', 'agent_task')),
          freshness_state TEXT,
          created_at INTEGER,
          updated_at INTEGER NOT NULL,
          raw_json TEXT NOT NULL,
          synced_at INTEGER NOT NULL,
          PRIMARY KEY (principal_id, workspace_id, id),
          FOREIGN KEY (principal_id, workspace_id)
            REFERENCES product_workspaces(principal_id, id)
            ON DELETE CASCADE
        );

        CREATE INDEX idx_product_conversations_principal_updated_at
          ON product_conversations(principal_id, updated_at DESC);

        CREATE INDEX idx_product_conversations_principal_workspace_updated_at
          ON product_conversations(principal_id, workspace_id, updated_at DESC);
      `);
    },
  },
  {
    name: "partition product cache by principal and audience",
    version: 9,
    up(database) {
      database.exec(`
        DROP TABLE product_conversations;
        DROP TABLE product_workspaces;

        CREATE TABLE product_workspaces (
          principal_id TEXT NOT NULL,
          audience TEXT NOT NULL
            CHECK (length(audience) > 0 AND audience = trim(audience)),
          id TEXT NOT NULL,
          name TEXT NOT NULL,
          raw_json TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (principal_id, audience, id)
        );

        CREATE TABLE product_conversations (
          principal_id TEXT NOT NULL,
          audience TEXT NOT NULL
            CHECK (length(audience) > 0 AND audience = trim(audience)),
          workspace_id TEXT NOT NULL,
          id TEXT NOT NULL,
          title TEXT NOT NULL,
          status TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('user_chat', 'agent_task')),
          freshness_state TEXT,
          created_at INTEGER,
          updated_at INTEGER NOT NULL,
          raw_json TEXT NOT NULL,
          synced_at INTEGER NOT NULL,
          PRIMARY KEY (principal_id, audience, workspace_id, id),
          FOREIGN KEY (principal_id, audience, workspace_id)
            REFERENCES product_workspaces(principal_id, audience, id)
            ON DELETE CASCADE
        );

        CREATE INDEX idx_product_conversations_partition_updated_at
          ON product_conversations(principal_id, audience, updated_at DESC);

        CREATE INDEX idx_product_conversations_partition_workspace_updated_at
          ON product_conversations(
            principal_id,
            audience,
            workspace_id,
            updated_at DESC
          );
      `);
    },
  },
  {
    name: "retire workspace-owned conversation cache rows",
    version: 10,
    up(database) {
      database.exec(`
        DROP TABLE product_conversations;
        DROP TABLE product_workspaces;

        CREATE TABLE product_workspaces (
          principal_id TEXT NOT NULL,
          audience TEXT NOT NULL
            CHECK (length(audience) > 0 AND audience = trim(audience)),
          id TEXT NOT NULL,
          group_id TEXT NOT NULL
            CHECK (length(group_id) > 0 AND group_id = trim(group_id)),
          name TEXT NOT NULL,
          raw_json TEXT NOT NULL,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (principal_id, audience, id),
          UNIQUE (principal_id, audience, id, group_id)
        );

        CREATE TABLE product_conversations (
          principal_id TEXT NOT NULL,
          audience TEXT NOT NULL
            CHECK (length(audience) > 0 AND audience = trim(audience)),
          workspace_id TEXT NOT NULL,
          group_id TEXT NOT NULL
            CHECK (length(group_id) > 0 AND group_id = trim(group_id)),
          id TEXT NOT NULL,
          title TEXT NOT NULL,
          status TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('user_chat', 'agent_task')),
          freshness_state TEXT,
          created_at INTEGER,
          updated_at INTEGER NOT NULL,
          raw_json TEXT NOT NULL,
          synced_at INTEGER NOT NULL,
          PRIMARY KEY (principal_id, audience, group_id, id),
          FOREIGN KEY (principal_id, audience, workspace_id, group_id)
            REFERENCES product_workspaces(principal_id, audience, id, group_id)
            ON DELETE CASCADE
        );

        CREATE INDEX idx_product_conversations_partition_updated_at
          ON product_conversations(principal_id, audience, updated_at DESC);

        CREATE INDEX idx_product_conversations_partition_workspace_updated_at
          ON product_conversations(
            principal_id,
            audience,
            workspace_id,
            updated_at DESC
          );

        CREATE INDEX idx_product_conversations_partition_group_updated_at
          ON product_conversations(
            principal_id,
            audience,
            group_id,
            updated_at DESC
          );
      `);
    },
  },
];

export function applyLocalDataMigrations(
  database: DatabaseSync,
  migrations: readonly LocalDataMigration[] = LOCAL_DATA_MIGRATIONS
) {
  let currentVersion = readUserVersion(database);
  for (const migration of migrations.toSorted(
    (left, right) => left.version - right.version
  )) {
    if (migration.version <= currentVersion) {
      continue;
    }

    if (migration.version !== currentVersion + 1) {
      throw new Error(
        `Local data migration ${migration.version} cannot run after schema ${currentVersion}.`
      );
    }

    database.exec("BEGIN IMMEDIATE");
    try {
      migration.up(database);
      database.exec(`PRAGMA user_version = ${migration.version}`);
      database.exec("COMMIT");
      currentVersion = migration.version;
    } catch (error) {
      rollback(database);
      throw error;
    }
  }
}

export class LocalDataService {
  readonly #database: DatabaseSync;
  readonly #now: () => number;

  private constructor({
    database,
    now,
  }: {
    database: DatabaseSync;
    now: () => number;
  }) {
    this.#database = database;
    this.#now = now;
  }

  static open({
    databasePath,
    migrations = LOCAL_DATA_MIGRATIONS,
    now = Date.now,
  }: {
    databasePath: string;
    migrations?: readonly LocalDataMigration[];
    now?: () => number;
  }) {
    if (databasePath !== ":memory:") {
      mkdirSync(dirname(databasePath), { recursive: true });
    }

    const database = new DatabaseSync(databasePath);
    database.exec("PRAGMA foreign_keys = ON");
    database.exec("PRAGMA journal_mode = WAL");
    applyLocalDataMigrations(database, migrations);

    return new LocalDataService({ database, now });
  }

  close() {
    this.#database.close();
  }

  listProductInboxItems({
    audience,
    limit = 50,
    principalId,
    workspaceId,
  }: {
    audience: string;
    limit?: number | undefined;
    principalId: string;
    workspaceId?: string | undefined;
  }): LocalProductInboxItem[] {
    assertNormalizedLocalDataAudience(audience);
    const rows = this.#database
      .prepare(
        `
          SELECT
            product_conversations.id AS conversation_id,
            product_conversations.workspace_id,
            product_conversations.group_id,
            product_conversations.title,
            product_conversations.status,
            product_conversations.kind,
            product_conversations.freshness_state,
            product_conversations.updated_at,
            product_conversations.raw_json AS conversation_raw_json,
            product_workspaces.name AS workspace_name
          FROM product_conversations
          INNER JOIN product_workspaces
            ON product_workspaces.principal_id = product_conversations.principal_id
           AND product_workspaces.audience = product_conversations.audience
           AND product_workspaces.id = product_conversations.workspace_id
          WHERE product_conversations.principal_id = ?
            AND product_conversations.audience = ?
            AND (? IS NULL OR product_conversations.workspace_id = ?)
            AND product_conversations.kind IN ('user_chat', 'agent_task')
          ORDER BY product_conversations.updated_at DESC, product_conversations.id ASC
          LIMIT ?
        `
      )
      .all(
        principalId,
        audience,
        workspaceId ?? null,
        workspaceId ?? null,
        limit
      ) as Array<{
      conversation_id: string;
      conversation_raw_json: string;
      freshness_state: "fresh" | "stale" | "unknown" | null;
      group_id: string;
      kind: ProductConversationKind;
      status: string;
      title: string;
      updated_at: number;
      workspace_id: string;
      workspace_name: string;
    }>;

    return rows.map((row) => ({
      audience,
      conversationId: row.conversation_id,
      raw: JSON.parse(row.conversation_raw_json) as LocalDataJsonValue,
      groupId: row.group_id,
      ...(row.freshness_state === null ? {} : { freshness: row.freshness_state }),
      id: `${row.group_id}:${row.conversation_id}`,
      kind: row.kind,
      source: "salix.conversation",
      status: row.status,
      title: row.title,
      updatedAt: row.updated_at,
      workspaceId: row.workspace_id,
      workspaceName: row.workspace_name,
    }));
  }

  listProductWorkspaces({
    audience,
    principalId,
  }: {
    audience: string;
    principalId: string;
  }): ProductWorkspaceInput[] {
    assertNormalizedLocalDataAudience(audience);
    const rows = this.#database
      .prepare(
        `
          SELECT id, group_id, name, raw_json
          FROM product_workspaces
          WHERE principal_id = ? AND audience = ?
          ORDER BY name ASC, id ASC
        `
      )
      .all(principalId, audience) as Array<{
      id: string;
      group_id: string;
      name: string;
      raw_json: string;
    }>;

    return rows.map((row) => ({
      audience,
      groupId: row.group_id,
      id: row.id,
      name: row.name,
      principalId,
      raw: JSON.parse(row.raw_json) as unknown,
    }));
  }

  schemaVersion() {
    return readUserVersion(this.#database);
  }

  applyProductInboxSync(input: ProductInboxCacheApplyInput) {
    assertProductInboxCacheApplyInput(input);
    const { audience, conversations, principalId, workspaces } = input;
    this.#runTransaction(() => {
      for (const workspace of workspaces.items) {
        this.upsertProductWorkspace(workspace);
      }
      if (workspaces.mode === "replace") {
        this.#deleteAbsentProductWorkspaces(principalId, audience, workspaces.items);
      }

      if (!conversations) return;

      for (const conversation of conversations.items) {
        this.upsertProductConversation(conversation);
      }
      if (conversations.mode === "replace") {
        this.#deleteAbsentProductWorkspaceConversations({
          conversations: conversations.items,
          principalId,
          audience,
          workspaceId: conversations.workspaceId,
        });
      }
    });
  }

  upsertProductConversation(input: ProductConversationInput) {
    assertNormalizedLocalDataAudience(input.audience);
    const updatedAt = input.updatedAt ?? input.createdAt ?? this.#now();

    this.#database
      .prepare(
        `
          INSERT INTO product_conversations (
            principal_id,
            audience,
            workspace_id,
            group_id,
            id,
            title,
            status,
            kind,
            freshness_state,
            created_at,
            updated_at,
            raw_json,
            synced_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(principal_id, audience, group_id, id) DO UPDATE SET
            workspace_id = excluded.workspace_id,
            title = excluded.title,
            status = excluded.status,
            kind = excluded.kind,
            freshness_state = excluded.freshness_state,
            created_at = COALESCE(product_conversations.created_at, excluded.created_at),
            updated_at = excluded.updated_at,
            raw_json = excluded.raw_json,
            synced_at = excluded.synced_at
        `
      )
      .run(
        input.principalId,
        input.audience,
        input.workspaceId,
        input.groupId,
        input.id,
        input.title,
        input.status,
        input.kind,
        input.freshness ?? null,
        input.createdAt ?? null,
        updatedAt,
        JSON.stringify(input.raw ?? null),
        this.#now()
      );
  }

  upsertProductWorkspace(input: ProductWorkspaceInput) {
    assertNormalizedLocalDataAudience(input.audience);
    this.#database
      .prepare(
        `
          INSERT INTO product_workspaces (
            principal_id,
            audience,
            id,
            group_id,
            name,
            raw_json,
            updated_at
          )
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(principal_id, audience, id) DO UPDATE SET
            group_id = excluded.group_id,
            name = excluded.name,
            raw_json = excluded.raw_json,
            updated_at = excluded.updated_at
        `
      )
      .run(
        input.principalId,
        input.audience,
        input.id,
        input.groupId,
        input.name,
        JSON.stringify(input.raw ?? null),
        this.#now()
      );
  }

  referencedBlobIds() {
    const rows = this.#database
      .prepare(
        `
          SELECT DISTINCT blob_id
          FROM local_blob_refs
          ORDER BY blob_id
        `
      )
      .all() as Array<{ blob_id: string }>;

    return rows.map((row) => row.blob_id);
  }

  #deleteAbsentProductWorkspaces(
    principalId: string,
    audience: string,
    workspaces: ReadonlyArray<{ id: string }>
  ) {
    if (workspaces.length === 0) {
      this.#database
        .prepare(
          `
            DELETE FROM product_workspaces
            WHERE principal_id = ? AND audience = ?
          `
        )
        .run(principalId, audience);
      return;
    }

    const placeholders = workspaces.map(() => "?").join(", ");
    this.#database
      .prepare(
        `
          DELETE FROM product_workspaces
          WHERE principal_id = ?
            AND audience = ?
            AND id NOT IN (${placeholders})
        `
      )
      .run(principalId, audience, ...workspaces.map((workspace) => workspace.id));
  }

  #deleteAbsentProductWorkspaceConversations({
    audience,
    conversations,
    principalId,
    workspaceId,
  }: {
    audience: string;
    conversations: ReadonlyArray<{ id: string }>;
    principalId: string;
    workspaceId: string;
  }) {
    if (conversations.length === 0) {
      this.#database
        .prepare(
          `
            DELETE FROM product_conversations
            WHERE principal_id = ? AND audience = ? AND workspace_id = ?
          `
        )
        .run(principalId, audience, workspaceId);
      return;
    }

    const placeholders = conversations.map(() => "?").join(", ");
    this.#database
      .prepare(
        `
          DELETE FROM product_conversations
          WHERE principal_id = ?
            AND audience = ?
            AND workspace_id = ?
            AND id NOT IN (${placeholders})
        `
      )
      .run(principalId, audience, workspaceId, ...conversations.map((item) => item.id));
  }

  #runTransaction(operation: () => void) {
    this.#database.exec("BEGIN IMMEDIATE");
    try {
      operation();
      this.#database.exec("COMMIT");
    } catch (error) {
      rollback(this.#database);
      throw error;
    }
  }
}

function readUserVersion(database: DatabaseSync) {
  const row = database.prepare("PRAGMA user_version").get() as
    | { user_version?: number }
    | undefined;

  return row?.user_version ?? 0;
}

function rollback(database: DatabaseSync) {
  try {
    database.exec("ROLLBACK");
  } catch {
    // A migration failure can leave SQLite outside a transaction if BEGIN itself failed.
  }
}

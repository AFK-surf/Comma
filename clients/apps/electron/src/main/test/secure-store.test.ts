import {
  mkdir,
  mkdtemp,
  open,
  readFile,
  readdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const electronMocks = vi.hoisted(() => ({
  encryptionAvailable: true,
  isEncryptionAvailable: vi.fn(() => electronMocks.encryptionAvailable),
  logWarn: vi.fn(),
  // Reversible stand-in for Electron's OS-backed cipher. The persisted bytes
  // intentionally do not contain the plaintext bearer.
  encryptString: vi.fn((plain: string) =>
    Buffer.from(Buffer.from(plain, "utf8").toString("base64"), "utf8")
  ),
  decryptString: vi.fn((buf: Buffer) =>
    Buffer.from(buf.toString("utf8"), "base64").toString("utf8")
  ),
}));

vi.mock("electron", () => ({
  app: { getPath: () => tmpdir() },
  safeStorage: {
    decryptString: electronMocks.decryptString,
    encryptString: electronMocks.encryptString,
    isEncryptionAvailable: electronMocks.isEncryptionAvailable,
  },
}));

vi.mock("electron-log/main", () => ({
  default: { warn: electronMocks.logWarn },
}));

import {
  SecureSessionStore,
  type SecureSessionFileHandle,
  type SecureSessionFileSystem,
  type SecureSessionInput,
  type SecureSessionStoreOptions,
} from "../secure-store";

describe("SecureSessionStore", () => {
  let dir: string;
  let filePath: string;

  beforeEach(async () => {
    electronMocks.encryptionAvailable = true;
    electronMocks.isEncryptionAvailable
      .mockReset()
      .mockImplementation(() => electronMocks.encryptionAvailable);
    electronMocks.encryptString
      .mockReset()
      .mockImplementation((plain: string) =>
        Buffer.from(Buffer.from(plain, "utf8").toString("base64"), "utf8")
      );
    electronMocks.decryptString
      .mockReset()
      .mockImplementation((buf: Buffer) =>
        Buffer.from(buf.toString("utf8"), "base64").toString("utf8")
      );
    electronMocks.logWarn.mockReset();
    dir = await mkdtemp(join(tmpdir(), "comma-secure-store-"));
    filePath = join(dir, "secure-session.bin");
  });

  afterEach(async () => {
    await rm(dir, { force: true, recursive: true });
  });

  it("requires explicit initialization before exposing memory state", async () => {
    const store = new SecureSessionStore(filePath);

    expect(() => store.getVaultSnapshot()).toThrow("not initialized");

    await store.initialize();
    expect(store.getVaultSnapshot()).toMatchObject({
      cleanup: { revocation: "idle" },
      pendingRevocations: [],
      status: "readable",
      storageVersion: null,
      vaultRevision: 0,
    });
    expect(store.getVaultSnapshot()).not.toHaveProperty("active");
  });

  it("persists the session encrypted before publishing it", async () => {
    const store = await openStore();
    await store.setSession(
      sessionInput({
        audience: "https://salix",
        email: "a@b.com",
        token: "secret-123",
      })
    );

    expect(store.getVaultSnapshot()).toMatchObject({
      active: {
        audience: "https://salix",
        email: "a@b.com",
        token: "secret-123",
        userId: "user-1",
      },
      cleanup: { revocation: "idle" },
      status: "readable",
      vaultRevision: 1,
    });
    expect(await readFile(filePath, "utf8")).not.toContain("secret-123");
    expect(await readDecryptedEnvelope()).toEqual({
      active: strictCredential({
        audience: "https://salix",
        email: "a@b.com",
        token: "secret-123",
      }),
      pendingRevocations: [],
      vaultRevision: 1,
      version: 3,
    });
  });

  it("atomically adopts a replacement auth credential only over an exact superseded active", async () => {
    const store = await openStore();
    const original = sessionInput({
      audience: "https://salix",
      sessionId: "session-original",
      token: "secret-original",
      userId: "user-original",
    });
    const replacement = sessionInput({
      audience: "https://salix",
      sessionId: "session-replacement",
      token: "secret-replacement",
      userId: "user-replacement",
    });
    await store.setSession(original);

    await store.setSession(replacement, {
      supersededCredentials: [
        strictCredential({
          audience: "https://salix",
          sessionId: "session-original",
          token: "secret-original",
          userId: "user-original",
        }),
      ],
    });

    expect(store.getVaultSnapshot()).toMatchObject({
      active: {
        sessionId: "session-replacement",
        token: "secret-replacement",
        userId: "user-replacement",
      },
      pendingRevocations: [
        {
          audience: "https://salix",
          sessionId: "session-original",
          token: "secret-original",
        },
      ],
      status: "readable",
    });
    expect((await openStore()).getVaultSnapshot()).toMatchObject({
      active: {
        sessionId: "session-replacement",
        token: "secret-replacement",
      },
      pendingRevocations: [
        {
          sessionId: "session-original",
          token: "secret-original",
        },
      ],
      status: "readable",
    });
  });

  it("records a superseded issued credential even when it never became active", async () => {
    const store = await openStore();

    await store.setSession(
      sessionInput({
        sessionId: "session-b",
        token: "secret-b",
        userId: "user-b",
      }),
      {
        supersededCredentials: [
          strictCredential({
            sessionId: "session-a",
            token: "secret-a",
            userId: "user-a",
          }),
        ],
      }
    );

    expect(store.getVaultSnapshot()).toMatchObject({
      active: {
        sessionId: "session-b",
        token: "secret-b",
      },
      pendingRevocations: [
        {
          audience: "https://salix",
          sessionId: "session-a",
          token: "secret-a",
        },
      ],
      status: "readable",
    });
  });

  it("refuses replacement auth over a credential with a different exact session identity", async () => {
    const store = await openStore();
    await store.setSession(
      sessionInput({
        sessionId: "session-original",
        token: "secret-shared",
      })
    );

    await expect(
      store.setSession(
        sessionInput({
          sessionId: "session-replacement",
          token: "secret-replacement",
        }),
        {
          supersededCredentials: [
            strictCredential({
              sessionId: "session-not-original",
              token: "secret-shared",
            }),
          ],
        }
      )
    ).rejects.toThrow("Sign out the current session");

    expect(store.getVaultSnapshot()).toMatchObject({
      active: {
        sessionId: "session-original",
        token: "secret-shared",
      },
      pendingRevocations: [],
      status: "readable",
    });
  });

  it("discards an invalid v3 envelope before allowing a replacement login", async () => {
    await writeEncryptedEnvelope({
      active: { ...strictCredential(), refreshToken: "rejected" },
      pendingRevocations: [],
      vaultRevision: 1,
      version: 3,
    });
    const store = await openStore();
    expect(store.getVaultSnapshot()).toMatchObject({
      status: "readable",
      cleanup: { revocation: "idle" },
    });
    expect(activeToken(store)).toBe("");
    await expect(readFile(filePath)).rejects.toMatchObject({ code: "ENOENT" });
    await store.setSession(sessionInput({ token: "replacement" }));
    expect(activeToken(await openStore())).toBe("replacement");
  });

  it("durably removes a retired v2 envelope instead of migrating it", async () => {
    await writeEncryptedEnvelope({
      active: {
        apiBaseUrl: "https://api-b.comma.example",
        email: "person@example.com",
        token: "active-b",
      },
      pendingRevocations: [
        { apiBaseUrl: "https://api-a.comma.example", token: "pending-a" },
      ],
      version: 2,
    });
    const store = await openStore();

    expect(store.getVaultSnapshot()).toMatchObject({
      pendingRevocations: [],
      status: "readable",
      storageVersion: null,
      vaultRevision: 0,
    });
    await expect(readFile(filePath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("rejects a stale opaque CAS and adopts the winning vault", async () => {
    await writeEncryptedEnvelope({
      pendingRevocations: [
        { audience: "https://api-a.comma.example", token: "pending-a" },
      ],
      vaultRevision: 1,
      version: 3,
    });
    const staleStore = await openStore();
    const winningStore = await openStore();
    const stale = staleStore.getVaultSnapshot();
    expect(stale.status).toBe("readable");

    await winningStore.queueRevocation({
      audience: "https://api-b.comma.example",
      token: "pending-b",
    });
    const result =
      stale.status === "readable"
        ? await staleStore.compareAndSetVault(
            {
              sourceIdentity: stale.sourceIdentity,
              vaultRevision: stale.vaultRevision,
            },
            {
              pendingRevocations: [
                {
                  audience: "https://api-a.comma.example",
                  token: "pending-a",
                },
              ],
            }
          )
        : undefined;

    expect(result).toBeNull();
    expect(staleStore.getVaultSnapshot()).toMatchObject({
      pendingRevocations: [
        { audience: "https://api-a.comma.example", token: "pending-a" },
        { audience: "https://api-b.comma.example", token: "pending-b" },
      ],
      status: "readable",
      storageVersion: 3,
      vaultRevision: 2,
    });
  });

  it("keeps the canonical vault snapshot memory-only after initialization", async () => {
    const readPersisted = vi.fn((path: string) => readFile(path));
    const fileSystem = createFileSystem({ readFile: readPersisted });
    const store = await SecureSessionStore.open(filePath, { fileSystem });

    expect(readPersisted).toHaveBeenCalledTimes(1);
    await store.setSession(sessionInput({ token: "secret-123" }));
    for (let index = 0; index < 20; index += 1) {
      expect(activeToken(store)).toBe("secret-123");
    }
    expect(readPersisted).toHaveBeenCalledTimes(2);
  });

  it("keeps a session volatile when encryption fails after the availability check", async () => {
    const store = await openStore();
    electronMocks.encryptString.mockImplementationOnce(() => {
      throw new Error("keychain unavailable");
    });
    await store.setSession(sessionInput({ token: "secret-123" }));
    expect(activeToken(store)).toBe("secret-123");
    await store.refresh();
    expect(activeToken(store)).toBe("secret-123");
    await expect(readFile(filePath)).rejects.toMatchObject({ code: "ENOENT" });
    expect(activeToken(await openStore())).toBe("");
  });

  it("keeps login, reconcile and revocation in memory without persisting a bearer", async () => {
    electronMocks.encryptionAvailable = false;
    const store = await openStore();
    await store.setSession(sessionInput({ token: "secret-123" }));
    expect(activeToken(store)).toBe("secret-123");
    await store.refresh();
    const snapshot = store.getVaultSnapshot();
    if (snapshot.status !== "readable") throw new Error("Expected readable vault");
    await expect(
      store.compareAndSetVault(snapshot, {
        active: strictCredential({ token: "secret-123" }),
        pendingRevocations: [],
      })
    ).resolves.toMatchObject({ status: "readable", active: { token: "secret-123" } });
    await expect(
      store.compareAndSetVault(snapshot, { pendingRevocations: [] })
    ).resolves.toBeNull();
    await store.beginSignOut();
    expect(activeToken(store)).toBe("");
    expect(pendingRevocations(store)).toHaveLength(1);
    await store.refresh();
    expect(pendingRevocations(store)).toHaveLength(1);
    await store.completeRevocation(pendingRevocations(store)[0]!);
    expect(pendingRevocations(store)).toEqual([]);
    expect(electronMocks.encryptString).not.toHaveBeenCalled();
    await expect(readFile(filePath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("removes old disk custody before memory login and never resurrects it on recovery", async () => {
    const writer = await openStore();
    await writer.setSession(sessionInput({ token: "original-secret" }));
    electronMocks.encryptionAvailable = false;
    const replacement = await openStore();
    expect(activeToken(replacement)).toBe("");
    await expect(readFile(filePath)).rejects.toMatchObject({ code: "ENOENT" });
    await replacement.setSession(sessionInput({ token: "replacement-secret" }));
    electronMocks.encryptionAvailable = true;
    await replacement.refresh();
    expect(activeToken(replacement)).toBe("replacement-secret");
    expect(activeToken(await openStore())).toBe("");
  });

  it("preserves known active and pending credentials when encryption is lost during use", async () => {
    const store = await openStore();
    await store.setSession(sessionInput({ token: "active" }));
    await store.queueRevocation({ audience: "https://salix", token: "pending" });
    electronMocks.encryptionAvailable = false;
    await store.refresh();
    expect(activeToken(store)).toBe("active");
    expect(pendingRevocations(store)).toEqual([
      { audience: "https://salix", token: "pending" },
    ]);
    await expect(readFile(filePath)).rejects.toMatchObject({ code: "ENOENT" });
    await store.beginSignOut();
    expect(activeToken(store)).toBe("");
    expect(pendingRevocations(store)).toHaveLength(2);
  });

  it("does not revive a stale cached account when disk custody changed before keychain loss", async () => {
    const first = await openStore();
    await first.setSession(sessionInput({ token: "account-a" }));
    const second = await openStore();
    await second.beginSignOut();
    await second.setSession(sessionInput({ token: "account-b" }));
    electronMocks.encryptionAvailable = false;
    await first.refresh();
    expect(activeToken(first)).toBe("");
    await expect(readFile(filePath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("does not replace old custody when durable removal fails", async () => {
    const writer = await openStore();
    await writer.setSession(sessionInput({ token: "original-secret" }));
    const original = await readFile(filePath);
    electronMocks.encryptionAvailable = false;
    const blocked = await SecureSessionStore.open(filePath, {
      fileSystem: createFileSystem({
        remove: async () => {
          throw new Error("permission denied");
        },
      }),
    });
    expect(blocked.getVaultSnapshot()).toMatchObject({ status: "indeterminate" });
    await expect(
      blocked.setSession(sessionInput({ token: "replacement" }))
    ).rejects.toThrow("existing session state cannot be replaced");
    expect(await readFile(filePath)).toEqual(original);
  });

  it.each(["unavailable encryption", "undecryptable", "retired v2"])(
    "retains removal uncertainty across refresh for %s custody",
    async (reason) => {
      const original = await SecureSessionStore.open(filePath);
      await original.setSession(sessionInput());
      if (reason === "unavailable encryption")
        electronMocks.encryptionAvailable = false;
      if (reason === "undecryptable")
        electronMocks.decryptString.mockImplementation(() => {
          throw new Error("unreadable");
        });
      if (reason === "retired v2") await writeEncryptedEnvelope({ version: 2 });
      const store = await SecureSessionStore.open(filePath, {
        fileSystem: createFaultFileSystem("directory-sync", { persistent: true }),
      });
      expect(store.getVaultSnapshot().status).toBe("indeterminate");
      await expect(store.refresh()).rejects.toThrow("injected directory-sync");
      expect(store.getVaultSnapshot().status).toBe("indeterminate");
      await expect(store.setSession(sessionInput())).rejects.toThrow(
        "injected directory-sync"
      );
      expect(store.getVaultSnapshot().status).toBe("indeterminate");
    }
  );

  it("durably signs out if encryption becomes unavailable", async () => {
    const store = await openStore();
    await store.setSession(
      sessionInput({
        audience: "https://salix",
        token: "secret-123",
      })
    );
    electronMocks.encryptionAvailable = false;

    await store.beginSignOut();

    expect(activeToken(store)).toBe("");
    expect(pendingRevocations(store)).toEqual([
      {
        audience: "https://salix",
        sessionId: "session-secret-123",
        token: "secret-123",
      },
    ]);
    electronMocks.encryptionAvailable = true;
    expect(activeToken(await openStore())).toBe("");
  });

  it("loads a session once during startup", async () => {
    const writer = await openStore();
    await writer.setSession(sessionInput({ email: "a@b.com", token: "secret-123" }));

    const reader = await openStore();
    expect(reader.getVaultSnapshot()).toMatchObject({
      active: {
        email: "a@b.com",
        token: "secret-123",
      },
      status: "readable",
    });
  });

  it("durably removes the active bearer and retains an encrypted revocation", async () => {
    const store = await openStore();
    await store.setSession(
      sessionInput({
        audience: "https://salix",
        email: "a@b.com",
        token: "secret-123",
      })
    );

    await store.beginSignOut();

    expect(activeToken(store)).toBe("");
    expect(store.getVaultSnapshot()).toMatchObject({
      cleanup: { pendingCount: 1, revocation: "pending" },
      status: "readable",
      vaultRevision: 2,
    });
    expect(pendingRevocations(store)).toEqual([
      {
        audience: "https://salix",
        sessionId: "session-secret-123",
        token: "secret-123",
      },
    ]);
    expect(await readFile(filePath, "utf8")).not.toContain("secret-123");

    const restarted = await openStore();
    expect(activeToken(restarted)).toBe("");
    expect(pendingRevocations(restarted)).toEqual([
      {
        audience: "https://salix",
        sessionId: "session-secret-123",
        token: "secret-123",
      },
    ]);
  });

  it("durably removes the empty envelope after final revocation", async () => {
    const store = await openStore();
    await store.setSession(
      sessionInput({
        audience: "https://salix",
        token: "secret-123",
      })
    );
    await store.beginSignOut();
    await store.completeRevocation({
      audience: "https://salix",
      sessionId: "session-secret-123",
      token: "secret-123",
    });

    expect(store.getVaultSnapshot()).toMatchObject({
      cleanup: { revocation: "idle" },
      status: "readable",
      vaultRevision: 3,
    });
    expect(await readDecryptedEnvelope()).toEqual({
      pendingRevocations: [],
      vaultRevision: 3,
      version: 3,
    });
    expect((await openStore()).getVaultSnapshot()).not.toHaveProperty("active");
  });

  it("does not create a file when signing out an already empty store", async () => {
    const store = await openStore();

    await store.beginSignOut();

    await expect(readFile(filePath)).rejects.toMatchObject({ code: "ENOENT" });
    expect(store.getVaultSnapshot()).not.toHaveProperty("active");
  });

  it("still removes the active bearer when the revocation queue is full", async () => {
    await writeEncryptedEnvelope({
      active: strictCredential({ token: "active-secret" }),
      pendingRevocations: Array.from({ length: 32 }, (_, index) => ({
        audience: "https://salix",
        token: `pending-${index}`,
      })),
      vaultRevision: 1,
      version: 3,
    });
    const store = await openStore();

    await store.beginSignOut();

    expect(activeToken(store)).toBe("");
    expect(pendingRevocations(store)).toHaveLength(32);
    expect(store.getVaultSnapshot()).toMatchObject({
      cleanup: { pendingCount: 32, revocation: "pending" },
      status: "readable",
    });
  });

  it("serializes concurrent mutations without losing queue entries", async () => {
    const store = await openStore();

    await expect(
      Promise.all([
        store.queueRevocation({ audience: "https://salix", token: "first" }),
        store.queueRevocation({ audience: "https://salix", token: "second" }),
      ])
    ).resolves.toEqual([true, true]);

    expect(pendingRevocations(store)).toEqual([
      { audience: "https://salix", token: "first" },
      { audience: "https://salix", token: "second" },
    ]);
    expect(pendingRevocations(await openStore())).toEqual(pendingRevocations(store));
  });

  it("does not remove a newer active session that only shares the stale token", async () => {
    const store = await openStore();
    await store.setSession(
      sessionInput({
        sessionId: "session-b",
        token: "shared-token",
        userId: "user-b",
      })
    );

    await expect(
      store.queueRevocation({
        audience: "https://salix",
        sessionId: "session-a",
        token: "shared-token",
      })
    ).resolves.toBe(true);

    expect(store.getVaultSnapshot()).toMatchObject({
      active: {
        sessionId: "session-b",
        token: "shared-token",
        userId: "user-b",
      },
      pendingRevocations: [
        {
          sessionId: "session-a",
          token: "shared-token",
        },
      ],
      status: "readable",
    });
  });

  it("never activates a rejected token after rename succeeds but directory sync fails", async () => {
    const store = await SecureSessionStore.open(filePath, {
      fileSystem: createFaultFileSystem("directory-sync"),
    });

    await expect(
      store.setSession(
        sessionInput({
          audience: "https://salix",
          token: "rejected-secret",
        })
      )
    ).rejects.toThrow("injected directory-sync");
    expect(activeToken(store)).toBe("");

    await expect(
      store.queueRevocation({
        audience: "https://salix",
        token: "rejected-secret",
      })
    ).resolves.toBe(true);

    expect(activeToken(store)).toBe("");
    expect(pendingRevocations(store)).toEqual([
      { audience: "https://salix", token: "rejected-secret" },
    ]);
    const restarted = await openStore();
    expect(activeToken(restarted)).toBe("");
    expect(pendingRevocations(restarted)).toEqual([
      { audience: "https://salix", token: "rejected-secret" },
    ]);
  });

  it("does not publish a disk candidate while durability remains uncertain", async () => {
    const store = await SecureSessionStore.open(filePath, {
      fileSystem: createFaultFileSystem("directory-sync", { persistent: true }),
    });

    await expect(
      store.setSession(
        sessionInput({
          audience: "https://salix",
          token: "uncertain-secret",
        })
      )
    ).rejects.toThrow("injected directory-sync");
    expect(activeToken(store)).toBe("");
    expect(store.getVaultSnapshot()).toMatchObject({
      problem: { code: "credential_mutation_uncertain" },
      status: "indeterminate",
    });

    await expect(store.refresh()).rejects.toThrow("injected directory-sync");

    expect(activeToken(store)).toBe("");
    expect(store.getVaultSnapshot()).toMatchObject({
      problem: { code: "credential_mutation_uncertain" },
      status: "indeterminate",
    });
    expect(activeToken(await openStore())).toBe("uncertain-secret");
  });

  it("does not sign out a different active token while queuing a rejection", async () => {
    const store = await openStore();
    await store.setSession(
      sessionInput({
        audience: "https://salix",
        token: "existing-secret",
      })
    );

    await expect(
      store.queueRevocation({
        audience: "https://salix",
        token: "rejected-secret",
      })
    ).resolves.toBe(true);

    expect(activeToken(store)).toBe("existing-secret");
    const restarted = await openStore();
    expect(activeToken(restarted)).toBe("existing-secret");
    expect(pendingRevocations(restarted)).toEqual([
      { audience: "https://salix", token: "rejected-secret" },
    ]);
  });

  it("deactivates a rejected token even when the retry queue is full", async () => {
    const queuedRevocations = Array.from({ length: 32 }, (_, index) => ({
      audience: "https://salix",
      token: `pending-${index}`,
    }));
    await writeEncryptedEnvelope({
      active: strictCredential({ token: "rejected-secret" }),
      pendingRevocations: queuedRevocations,
      vaultRevision: 1,
      version: 3,
    });
    const store = await openStore();

    await expect(
      store.queueRevocation({
        audience: "https://salix",
        token: "rejected-secret",
      })
    ).resolves.toBe(false);

    expect(activeToken(store)).toBe("");
    expect(pendingRevocations(store)).toEqual(queuedRevocations);
    const restarted = await openStore();
    expect(activeToken(restarted)).toBe("");
    expect(pendingRevocations(restarted)).toEqual(queuedRevocations);
  });

  it("durably removes a legacy bearer", async () => {
    await writeFile(
      filePath,
      electronMocks.encryptString(
        JSON.stringify({
          apiBaseUrl: "https://salix",
          email: "legacy@example.com",
          token: "legacy-secret",
          userId: "usr_legacy",
        })
      )
    );

    const store = await openStore();

    expect(activeToken(store)).toBe("");
    expect(store.getVaultSnapshot()).not.toHaveProperty("active");
    await expect(readFile(filePath)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("discards undecryptable custody without logging secrets or reviving the old session", async () => {
    await writeEncryptedEnvelope({
      active: strictCredential({ token: "original-secret" }),
      pendingRevocations: [],
      vaultRevision: 1,
      version: 3,
    });
    electronMocks.decryptString.mockImplementationOnce(() => {
      throw new Error("bad cipher original-secret");
    });
    const store = await openStore();
    expect(activeToken(store)).toBe("");
    await expect(readFile(filePath)).rejects.toMatchObject({ code: "ENOENT" });
    await store.setSession(sessionInput({ token: "replacement" }));
    expect(activeToken(await openStore())).toBe("replacement");
    expect(JSON.stringify(electronMocks.logWarn.mock.calls)).not.toContain(
      "original-secret"
    );
  });

  it("does not restore discarded custody when a transient decrypt failure recovers", async () => {
    await writeEncryptedEnvelope({
      active: strictCredential({ token: "original-secret" }),
      pendingRevocations: [],
      vaultRevision: 1,
      version: 3,
    });
    electronMocks.decryptString.mockImplementationOnce(() => {
      throw new Error("keychain temporarily unavailable");
    });
    const store = await openStore();
    await expect(store.refresh()).resolves.toBe(false);
    expect(activeToken(store)).toBe("");
    expect(activeToken(await openStore())).toBe("");
  });

  it.each([
    ["invalid JSON", "not-json", "stored session contains invalid JSON"],
    [
      "invalid schema",
      JSON.stringify({
        active: { token: "original-secret" },
        pendingRevocations: [{ audience: "", token: "invalid" }],
        vaultRevision: 1,
        version: 3,
      }),
      "stored session schema is invalid",
    ],
  ])(
    "removes an envelope with %s before accepting a replacement",
    async (_label, persisted, warning) => {
      await writeFile(filePath, electronMocks.encryptString(persisted));
      const store = await openStore();
      expect(store.getVaultSnapshot()).toMatchObject({ status: "readable" });
      await expect(readFile(filePath)).rejects.toMatchObject({ code: "ENOENT" });
      await store.setSession(sessionInput({ token: "replacement-secret" }));
      expect(activeToken(await openStore())).toBe("replacement-secret");
      expect(electronMocks.logWarn).toHaveBeenCalledWith(
        expect.stringContaining(warning)
      );
    }
  );

  it.each(["write", "file-sync", "rename", "directory-sync"] as const)(
    "leaves an old-or-new complete envelope after an injected %s failure",
    async (stage) => {
      const store = await SecureSessionStore.open(filePath, {
        fileSystem: createFaultFileSystem(stage),
      });

      await expect(
        store.setSession(
          sessionInput({ audience: "https://salix", token: "secret-123" })
        )
      ).rejects.toThrow(`injected ${stage}`);
      expect(activeToken(store)).toBe("");
      expect(temporaryFiles(await readdir(dir))).toEqual([]);

      const restarted = await openStore();
      expect(["", "secret-123"]).toContain(activeToken(restarted));
      expect(pendingRevocations(restarted)).toEqual([]);
    }
  );

  it.each(["write", "file-sync", "rename", "directory-sync"] as const)(
    "falls back to durable local sign-out after an injected %s failure",
    async (stage) => {
      const writer = await openStore();
      await writer.setSession(
        sessionInput({
          audience: "https://salix",
          token: "secret-123",
        })
      );
      const store = await SecureSessionStore.open(filePath, {
        fileSystem: createFaultFileSystem(stage),
      });

      await expect(store.beginSignOut()).resolves.toBeUndefined();

      expect(activeToken(store)).toBe("");
      expect(pendingRevocations(store)).toEqual([
        {
          audience: "https://salix",
          sessionId: "session-secret-123",
          token: "secret-123",
        },
      ]);
      expect(activeToken(await openStore())).toBe("");
      expect(temporaryFiles(await readdir(dir))).toEqual([]);
    }
  );

  it("does not quarantine itself after a failed atomic sign-out write", async () => {
    const writer = await openStore();
    await writer.setSession(
      sessionInput({
        audience: "https://salix",
        token: "secret-123",
      })
    );
    const store = await SecureSessionStore.open(filePath, {
      fileSystem: createFaultFileSystem("file-sync"),
    });

    await expect(store.beginSignOut()).resolves.toBeUndefined();
    await store.setSession(sessionInput({ token: "replacement-secret" }));

    expect(activeToken(store)).toBe("replacement-secret");
    expect(activeToken(await openStore())).toBe("replacement-secret");
    expect(temporaryFiles(await readdir(dir))).toEqual([]);
  });

  it("keeps the active bearer when neither replacement nor removal is durable", async () => {
    const writer = await openStore();
    await writer.setSession(
      sessionInput({
        audience: "https://salix",
        token: "secret-123",
      })
    );
    const faultFileSystem = createFaultFileSystem("write");
    const fileSystem = createFileSystem({
      ...faultFileSystem,
      async remove(path) {
        if (path === filePath) throw new Error("injected removal failure");
        await faultFileSystem.remove(path);
      },
    });
    const store = await SecureSessionStore.open(filePath, { fileSystem });

    await expect(store.beginSignOut()).rejects.toThrow(
      "could not securely persist sign-out"
    );

    expect(activeToken(store)).toBe("secret-123");
    expect(activeToken(await openStore())).toBe("secret-123");
    expect(temporaryFiles(await readdir(dir))).toEqual([]);
  });

  function openStore(options: SecureSessionStoreOptions = {}) {
    return SecureSessionStore.open(filePath, options);
  }

  async function writeEncryptedEnvelope(envelope: unknown) {
    await writeFile(filePath, electronMocks.encryptString(JSON.stringify(envelope)));
  }

  async function readDecryptedEnvelope() {
    return JSON.parse(electronMocks.decryptString(await readFile(filePath))) as unknown;
  }
});

function activeToken(store: SecureSessionStore) {
  const snapshot = store.getVaultSnapshot();
  return snapshot.status === "readable" ? (snapshot.active?.token ?? "") : "";
}

function pendingRevocations(store: SecureSessionStore) {
  const snapshot = store.getVaultSnapshot();
  return snapshot.status === "readable" ? snapshot.pendingRevocations : [];
}

function createFileSystem(
  overrides: Partial<SecureSessionFileSystem> = {}
): SecureSessionFileSystem {
  const fileSystem: SecureSessionFileSystem = {
    async mkdir(path) {
      await mkdir(path, { recursive: true });
    },
    async open(path, flags, mode) {
      return (await open(path, flags, mode)) as SecureSessionFileHandle;
    },
    readFile,
    async remove(path) {
      await rm(path, { force: true });
    },
    rename,
  };
  return { ...fileSystem, ...overrides };
}

type FaultStage = "directory-sync" | "file-sync" | "rename" | "write";

function createFaultFileSystem(
  stage: FaultStage,
  options: { persistent?: boolean } = {}
): SecureSessionFileSystem {
  const fileSystem = createFileSystem();
  let armed = true;
  const fail = (candidate: FaultStage) => {
    if (!armed || candidate !== stage) return;
    if (!options.persistent) armed = false;
    throw Object.assign(new Error(`injected ${stage}`), { code: "EIO" });
  };

  return {
    ...fileSystem,
    async open(path, flags, mode) {
      const handle = await fileSystem.open(path, flags, mode);
      return {
        close: () => handle.close(),
        async sync() {
          fail(flags === "r" ? "directory-sync" : "file-sync");
          await handle.sync();
        },
        async writeFile(data) {
          if (flags === "wx") fail("write");
          await handle.writeFile(data);
        },
      };
    },
    async rename(from, to) {
      fail("rename");
      await fileSystem.rename(from, to);
    },
  };
}

function temporaryFiles(entries: string[]) {
  return entries.filter(
    (entry) => entry.startsWith(".secure-session.bin.") && entry.endsWith(".tmp")
  );
}

function sessionInput(overrides: Partial<SecureSessionInput> = {}): SecureSessionInput {
  const token = overrides.token ?? "secret-123";
  return {
    audience: "https://salix",
    email: "person@example.com",
    expiresAtEpochSeconds: 1_900_000_000,
    sessionId: `session-${token}`,
    token,
    userId: "user-1",
    ...overrides,
  };
}

function strictCredential(
  overrides: Partial<{
    audience: string;
    email: string;
    expiresAtEpochSeconds: number;
    sessionId: string;
    token: string;
    userId: string;
  }> = {}
) {
  return {
    audience: "https://salix",
    email: "person@example.com",
    expiresAtEpochSeconds: 1_900_000_000,
    sessionId: "session-secret-123",
    token: "secret-123",
    userId: "user-1",
    ...overrides,
  };
}

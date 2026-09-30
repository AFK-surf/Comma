import { createHash, randomUUID } from "node:crypto";
import { mkdir, open, readFile, rename, rm, type FileHandle } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import {
  createSessionProblem,
  sessionCleanupSchema,
  sessionProblemSchema,
  type SessionCleanup,
  type SessionProblem,
} from "@comma/session-contract";
import { app, safeStorage } from "electron";
import log from "electron-log/main";
import { z } from "zod";
import {
  canonicalizeSessionAudience,
  securePendingSessionRevocationSchema,
  secureSessionActiveCredentialSchema,
  type SecurePendingSessionRevocationRecord,
  type SecureSessionActiveCredential,
} from "./modules/session/credential";

const SECURE_SESSION_FILE = "secure-session.bin";
const SECURE_SESSION_VERSION = 3;
const MAX_PENDING_REVOCATIONS = 32;
const UNREADABLE_SESSION_ERROR =
  "Stored session is unreadable; existing session state cannot be replaced.";
const UNINITIALIZED_SESSION_ERROR = "SecureSessionStore is not initialized.";
const TEMP_OPEN_ATTEMPTS = 3;
const CAS_ATTEMPTS = 4;
const MISSING_SOURCE_IDENTITY = "missing";

class VaultConflictError extends Error {
  constructor(readonly current: DiskReadResult) {
    super("Secure Session vault changed during mutation.");
  }
}

export class SecureSessionStoreError extends Error {
  readonly problem: SessionProblem;

  constructor(message: string, problem: SessionProblem) {
    super(message);
    this.name = "SecureSessionStoreError";
    this.problem = sessionProblemSchema.parse(problem);
  }
}

export type SecureSessionVaultActive = {
  credentialVersion: 3;
} & SecureSessionActiveCredential;

export interface SecureSessionInput {
  audience: string;
  email: string;
  expiresAtEpochSeconds: number;
  sessionId: string;
  token: string;
  userId: string;
}

export interface SecureSessionSetOptions {
  /**
   * A replacement authentication transaction records every known superseded
   * issued credential in the same envelope that adopts the winner. An existing
   * active credential must match this exact set; absence is also accepted.
   */
  supersededCredentials?: readonly SecureSessionActiveCredential[] | undefined;
}

export interface PendingSessionRevocationInput {
  audience: string;
  sessionId?: string | undefined;
  token: string;
}

interface StoredSessionEnvelopeV3 {
  version: typeof SECURE_SESSION_VERSION;
  vaultRevision: number;
  active?: SecureSessionActiveCredential | undefined;
  pendingRevocations: SecurePendingSessionRevocationRecord[];
}

interface ReadableStoredSessionEnvelope {
  active?: SecureSessionVaultActive | undefined;
  pendingRevocations: SecurePendingSessionRevocationRecord[];
  sourceIdentity: string;
  storageVersion: 3 | null;
  vaultRevision: number;
}

export interface SecureSessionVaultVersion {
  sourceIdentity: string;
  vaultRevision: number;
}

export type SecureSessionVaultSnapshot =
  | {
      active?: SecureSessionVaultActive | undefined;
      cleanup: SessionCleanup;
      pendingRevocations: SecurePendingSessionRevocationRecord[];
      sourceIdentity: string;
      status: "readable";
      storageVersion: 3 | null;
      vaultRevision: number;
    }
  | {
      cleanup: Extract<SessionCleanup, { revocation: "unknown" }>;
      problem: SessionProblem;
      status: "indeterminate";
    };

export interface SecureSessionVaultContents {
  active?: SecureSessionActiveCredential | undefined;
  pendingRevocations: SecurePendingSessionRevocationRecord[];
}

export interface SecureSessionFileHandle {
  close(): Promise<void>;
  sync(): Promise<void>;
  writeFile(data: Uint8Array): Promise<void>;
}

export interface SecureSessionFileSystem {
  mkdir(path: string): Promise<void>;
  open(
    path: string,
    flags: "r" | "wx",
    mode?: number | undefined
  ): Promise<SecureSessionFileHandle>;
  readFile(path: string): Promise<Buffer>;
  remove(path: string): Promise<void>;
  rename(from: string, to: string): Promise<void>;
}

export interface SecureSessionStoreOptions {
  fileSystem?: SecureSessionFileSystem | undefined;
  platform?: NodeJS.Platform | undefined;
  randomId?: (() => string) | undefined;
}

const storedSessionEnvelopeV3Schema = z.strictObject({
  active: secureSessionActiveCredentialSchema.optional(),
  pendingRevocations: z
    .array(securePendingSessionRevocationSchema)
    .max(MAX_PENDING_REVOCATIONS),
  vaultRevision: z.number().int().min(1).max(Number.MAX_SAFE_INTEGER),
  version: z.literal(SECURE_SESSION_VERSION),
});

const nodeFileSystem: SecureSessionFileSystem = {
  async mkdir(path) {
    await mkdir(path, { recursive: true });
  },
  open(path, flags, mode) {
    return open(path, flags, mode) as Promise<FileHandle>;
  },
  readFile,
  async remove(path) {
    await rm(path, { force: true });
  },
  rename,
};

type DiskReadResult =
  | {
      envelope: ReadableStoredSessionEnvelope;
      kind: "readable";
    }
  | { kind: "unusable" }
  | { kind: "unreadable" };

const writerTails = new Map<string, Promise<void>>();

/**
 * Main-owned Session vault. Persistent commits use encrypted source/revision
 * CAS; unavailable OS encryption selects process-lifetime memory custody after
 * durable disk removal. All local mutations use the same per-path writer queue.
 * See docs/clients.md.
 */
export class SecureSessionStore {
  private cached: ReadableStoredSessionEnvelope | undefined;
  private diskStateUncertain = false;
  // Sticky for this owner lifetime: keychain recovery must not restore an older account.
  private memoryOnly = false;
  private readonly filePath: string;
  private readonly fileSystem: SecureSessionFileSystem;
  private indeterminateProblem: SessionProblem | undefined;
  private initialization: Promise<void> | undefined;
  private initialized = false;
  private readonly platform: NodeJS.Platform;
  private readonly randomId: () => string;
  private revision = 0;

  constructor(filePath?: string, options: SecureSessionStoreOptions = {}) {
    this.filePath = filePath ?? join(app.getPath("userData"), SECURE_SESSION_FILE);
    this.fileSystem = options.fileSystem ?? nodeFileSystem;
    this.platform = options.platform ?? process.platform;
    this.randomId = options.randomId ?? randomUUID;
  }

  static async open(filePath?: string, options: SecureSessionStoreOptions = {}) {
    const store = new SecureSessionStore(filePath, options);
    await store.initialize();
    return store;
  }

  initialize() {
    this.initialization ??= this.initializeFromDisk();
    return this.initialization;
  }

  isAvailable() {
    return safeStorage.isEncryptionAvailable();
  }

  getVaultSnapshot(): SecureSessionVaultSnapshot {
    this.assertInitialized();
    if (this.diskStateUncertain) {
      return indeterminateVaultSnapshot(
        createSessionProblem("credential_mutation_uncertain", "reconcile")
      );
    }
    if (!this.cached) {
      return indeterminateVaultSnapshot(
        this.indeterminateProblem ??
          createSessionProblem("credential_store_unreadable", "initialize")
      );
    }

    return {
      ...(this.cached.active ? { active: cloneActive(this.cached.active) } : {}),
      cleanup: cleanupFor(this.cached.pendingRevocations),
      pendingRevocations: this.cached.pendingRevocations.map(clonePending),
      sourceIdentity: this.cached.sourceIdentity,
      status: "readable",
      storageVersion: this.cached.storageVersion,
      vaultRevision: this.cached.vaultRevision,
    };
  }

  /** Reconcile disk custody, or retain the current process-lifetime memory vault. */
  refresh() {
    return this.enqueueMutation(async () => {
      const previousRevision = this.revision;
      const result = await this.readPersistedEnvelope();

      if (this.diskStateUncertain && result.kind === "readable") {
        await this.syncDirectory(dirname(this.filePath));
      }

      await this.applyDiskReadResult(result, true, true);
      if (!this.cached) {
        throw this.unreadableError("reconcile");
      }
      return this.revision !== previousRevision;
    });
  }

  setSession(input: SecureSessionInput, options: SecureSessionSetOptions = {}) {
    const credential = parseSecureSessionInput(input);
    const supersededCredentials = (options.supersededCredentials ?? []).map(
      (candidate) => secureSessionActiveCredentialSchema.parse(candidate)
    );
    return this.enqueueMutation(async () => {
      await this.runCasMutation((envelope) => {
        let pendingRevocations = envelope.pendingRevocations;
        if (
          pendingRevocations.some((pending) => samePendingIdentity(pending, credential))
        ) {
          throw new Error(
            "A credential pending sign-out cleanup cannot become active."
          );
        }
        if (envelope.active) {
          const active = storedActiveCredential(envelope.active);
          if (
            !active ||
            !supersededCredentials.some((candidate) =>
              sameActiveCredentialIdentity(active, candidate)
            )
          ) {
            throw new Error(
              "Sign out the current session before starting another one."
            );
          }
        }

        for (const superseded of supersededCredentials) {
          if (sameActiveCredentialIdentity(superseded, credential)) continue;
          pendingRevocations = appendPendingRevocation(
            pendingRevocations,
            securePendingSessionRevocationSchema.parse({
              audience: superseded.audience,
              sessionId: superseded.sessionId,
              token: superseded.token,
            })
          );
        }
        if (!envelope.active && pendingRevocations.length >= MAX_PENDING_REVOCATIONS) {
          throw new Error(
            "Pending sign-out cleanup must finish before signing in again."
          );
        }

        return {
          contents: {
            active: credential,
            pendingRevocations,
          },
          value: undefined,
        };
      });
    });
  }

  /**
   * Removes only the exact active credential after a trusted current-session
   * result. Pending cleanup identity and order are preserved.
   */
  invalidateSession(input: {
    audience?: string | undefined;
    sessionId?: string | undefined;
    token: string;
  }) {
    const audience = input.audience
      ? canonicalizeSessionAudience(input.audience)
      : undefined;
    return this.enqueueMutation(async () =>
      this.runCasMutation((envelope) => {
        const active = envelope.active;
        if (
          !active ||
          active.token !== input.token ||
          (audience !== undefined && active.audience !== audience) ||
          (input.sessionId !== undefined && active.sessionId !== input.sessionId)
        ) {
          return { value: false };
        }

        return {
          contents: {
            pendingRevocations: envelope.pendingRevocations,
          },
          value: true,
        };
      })
    );
  }

  /**
   * Removes the active bearer only after a signed-out v3 envelope is durable.
   * If encryption fails, durable file removal remains the local security
   * boundary; only cleanup metadata may remain Main-memory-only.
   */
  beginSignOut() {
    return this.enqueueMutation(async () => {
      let target:
        | { audience: string; sessionId?: string | undefined; token: string }
        | undefined;
      let fallbackPending: SecurePendingSessionRevocationRecord[] | undefined;

      try {
        await this.runCasMutation((envelope) => {
          if (!target && envelope.active) {
            target = {
              audience: envelope.active.audience,
              sessionId: envelope.active.sessionId,
              token: envelope.active.token,
            };
          }
          if (!target) return { value: undefined };

          const active = envelope.active;
          if (
            !active ||
            active.token !== target.token ||
            active.audience !== target.audience
          ) {
            return { value: undefined };
          }

          let pendingRevocations = envelope.pendingRevocations;
          if (
            pendingRevocations.length < MAX_PENDING_REVOCATIONS ||
            pendingRevocations.some((pending) => samePendingIdentity(pending, target!))
          ) {
            pendingRevocations = appendPendingRevocation(
              pendingRevocations,
              securePendingSessionRevocationSchema.parse(target)
            );
          } else {
            log.warn(
              "[secure-store] revocation queue full; active session removed locally"
            );
          }
          fallbackPending = pendingRevocations;
          return {
            contents: { pendingRevocations },
            value: undefined,
          };
        });
      } catch (error) {
        if (!target || !fallbackPending) throw error;
        try {
          await this.removeEnvelopeDurably();
        } catch {
          throw new Error("Comma could not securely persist sign-out.");
        }
        this.commitEnvelope({
          pendingRevocations: fallbackPending,
          sourceIdentity: MISSING_SOURCE_IDENTITY,
          storageVersion: null,
          vaultRevision: 0,
        });
        log.warn("[secure-store] sign-out retry retained in-memory only");
      }
    });
  }

  queueRevocation(input: PendingSessionRevocationInput) {
    let pending: SecurePendingSessionRevocationRecord;
    try {
      pending = parsePendingRevocationInput(input);
    } catch {
      return Promise.resolve(false);
    }

    return this.enqueueMutation(async () => {
      let removesMatchingActive = false;
      let fallbackContents: SecureSessionVaultContents | undefined;
      try {
        return await this.runCasMutation((envelope) => {
          const active = envelope.active;
          removesMatchingActive = Boolean(
            active && pendingMatchesActive(pending, active)
          );
          const alreadyPending = envelope.pendingRevocations.some((candidate) =>
            samePendingIdentity(candidate, pending)
          );
          const canQueue =
            alreadyPending ||
            envelope.pendingRevocations.length < MAX_PENDING_REVOCATIONS;
          if (!removesMatchingActive && !canQueue) {
            return { value: false };
          }

          const pendingRevocations = canQueue
            ? appendPendingRevocation(envelope.pendingRevocations, pending)
            : envelope.pendingRevocations;
          if (
            !removesMatchingActive &&
            pendingRevocations === envelope.pendingRevocations
          ) {
            return { value: true };
          }

          fallbackContents = {
            ...(removesMatchingActive
              ? {}
              : { active: storedActiveCredential(active) }),
            pendingRevocations,
          };
          return {
            contents: fallbackContents,
            value: canQueue,
          };
        });
      } catch {
        if (!removesMatchingActive || !fallbackContents) {
          log.warn("[secure-store] failed to persist pending session revocation");
          return false;
        }

        try {
          await this.removeEnvelopeDurably();
          this.commitEnvelope({
            pendingRevocations: fallbackContents.pendingRevocations,
            sourceIdentity: MISSING_SOURCE_IDENTITY,
            storageVersion: null,
            vaultRevision: 0,
          });
          log.warn(
            "[secure-store] rejected session revocation retained in-memory only"
          );
          return fallbackContents.pendingRevocations.some((candidate) =>
            samePendingIdentity(candidate, pending)
          );
        } catch {
          log.warn("[secure-store] failed to persist pending session revocation");
          return false;
        }
      }
    });
  }

  completeRevocation(input: {
    audience: string;
    sessionId?: string | undefined;
    token: string;
  }) {
    const identity = {
      audience: canonicalizeSessionAudience(input.audience),
      ...(input.sessionId ? { sessionId: input.sessionId } : {}),
      token: input.token,
    };

    return this.enqueueMutation(async () => {
      await this.runCasMutation((envelope) => {
        const matching = envelope.pendingRevocations.filter((pending) =>
          pendingMatchesCompletion(pending, identity)
        );
        if (matching.length === 0) return { value: undefined };

        return {
          contents: {
            ...(envelope.active
              ? { active: storedActiveCredential(envelope.active) }
              : {}),
            pendingRevocations: envelope.pendingRevocations.filter(
              (pending) => !pendingMatchesCompletion(pending, identity)
            ),
          },
          value: undefined,
        };
      });
    });
  }

  /**
   * Opaque exact CAS for the authority/reconcile path.
   */
  compareAndSetVault(
    expected: SecureSessionVaultVersion,
    contentsValue: SecureSessionVaultContents
  ): Promise<SecureSessionVaultSnapshot | null> {
    const contents = parseVaultContents(contentsValue);
    return this.enqueueMutation(async () => {
      const actual = await this.readPersistedEnvelope();
      await this.applyDiskReadResult(actual, false, true);
      if (
        actual.kind !== "readable" ||
        actual.envelope.sourceIdentity !== expected.sourceIdentity ||
        actual.envelope.vaultRevision !== expected.vaultRevision
      ) {
        return null;
      }

      const committed = await this.persistEnvelopeCas(actual.envelope, contents);
      this.commitEnvelope(committed);
      return this.getVaultSnapshot();
    });
  }

  private async initializeFromDisk() {
    const result = await this.readPersistedEnvelope();
    await this.applyDiskReadResult(result, true, false);
    this.initialized = true;
  }

  private async ensureReadableEnvelope() {
    if (this.diskStateUncertain) {
      const result = await this.readPersistedEnvelope();
      if (result.kind === "readable") {
        try {
          await this.syncDirectory(dirname(this.filePath));
        } catch (error) {
          this.diskStateUncertain = true;
          throw error;
        }
      }
      await this.applyDiskReadResult(result, false, true);
    } else if (!this.cached) {
      await this.applyDiskReadResult(await this.readPersistedEnvelope(), false, true);
    }

    if (!this.cached) throw this.unreadableError("reconcile");
    return this.cached;
  }

  private async applyDiskReadResult(
    result: DiskReadResult,
    discardUnusable: boolean,
    publish: boolean
  ) {
    if (result.kind === "readable") {
      this.adoptEnvelope(result.envelope, publish);
      return;
    }

    if (discardUnusable && result.kind === "unusable") {
      try {
        await this.removeEnvelopeDurably();
        this.adoptEnvelope(emptyEnvelope(), publish);
        log.warn("[secure-store] removed unusable stored session");
        return;
      } catch {
        log.warn("[secure-store] failed to clear unusable stored session");
      }
    }

    this.cached = undefined;
    // An unreadable result cannot resolve a prior unlink/rename whose directory
    // sync failed. Reconcile must finish that sync before publishing custody.
    this.indeterminateProblem = createSessionProblem(
      "credential_store_unreadable",
      "initialize"
    );
  }

  private async readPersistedEnvelope(): Promise<DiskReadResult> {
    if (this.memoryOnly) {
      return { kind: "readable", envelope: this.cached! };
    }
    let encrypted: Buffer;
    try {
      encrypted = await this.fileSystem.readFile(this.filePath);
    } catch (error) {
      if (errorCode(error) === "ENOENT") {
        return {
          envelope: emptyEnvelope(),
          kind: "readable",
        };
      }
      log.warn("[secure-store] failed to read encrypted stored session");
      return { kind: "unreadable" };
    }

    if (!this.isAvailable()) {
      // Removing disk custody is required before claiming local absence or
      // adopting a volatile replacement. A failed removal still fails closed.
      try {
        const known =
          this.cached?.sourceIdentity === encryptedSourceIdentity(encrypted)
            ? this.cached
            : emptyEnvelope();
        const envelope = await this.enterMemoryStorage(known);
        return { kind: "readable", envelope };
      } catch {
        log.warn("[secure-store] failed to remove stored session before memory login");
        return { kind: "unreadable" };
      }
    }

    let decrypted: string;
    try {
      decrypted = safeStorage.decryptString(encrypted);
    } catch {
      log.warn("[secure-store] failed to decrypt stored session");
      return { kind: "unusable" };
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(decrypted);
    } catch {
      log.warn("[secure-store] stored session contains invalid JSON");
      return { kind: "unusable" };
    }

    try {
      return {
        envelope: v3InternalEnvelope(
          storedSessionEnvelopeV3Schema.parse(parsed),
          encryptedSourceIdentity(encrypted)
        ),
        kind: "readable",
      };
    } catch {
      log.warn("[secure-store] stored session schema is invalid");
      return { kind: "unusable" };
    }
  }

  private async runCasMutation<T>(
    mutate: (
      envelope: ReadableStoredSessionEnvelope
    ) => { contents?: SecureSessionVaultContents | undefined; value: T } | undefined
  ): Promise<T | undefined> {
    for (let attempt = 0; attempt < CAS_ATTEMPTS; attempt += 1) {
      const observed = await this.ensureReadableEnvelope();
      const mutation = mutate(observed);
      if (!mutation?.contents) return mutation?.value;

      try {
        const committed = await this.persistEnvelopeCas(observed, mutation.contents);
        this.commitEnvelope(committed);
        return mutation.value;
      } catch (error) {
        if (!(error instanceof VaultConflictError)) throw error;
        await this.applyDiskReadResult(error.current, false, true);
      }
    }

    throw new SecureSessionStoreError(
      "Secure Session vault changed too many times; reconcile before retrying.",
      createSessionProblem("credential_mutation_uncertain", "reconcile")
    );
  }

  private async persistEnvelopeCas(
    observed: ReadableStoredSessionEnvelope,
    contentsValue: SecureSessionVaultContents
  ) {
    const current = await this.readPersistedEnvelope();
    if (
      current.kind !== "readable" ||
      current.envelope.sourceIdentity !== observed.sourceIdentity ||
      current.envelope.vaultRevision !== observed.vaultRevision
    ) {
      throw new VaultConflictError(current);
    }

    const contents = parseVaultContents(contentsValue);
    const vaultRevision = incrementVaultRevision(observed.vaultRevision);
    const persisted = storedSessionEnvelopeV3Schema.parse({
      ...(contents.active ? { active: contents.active } : {}),
      pendingRevocations: contents.pendingRevocations,
      vaultRevision,
      version: SECURE_SESSION_VERSION,
    }) satisfies StoredSessionEnvelopeV3;
    let encrypted: Buffer | undefined;
    if (!this.memoryOnly && this.isAvailable()) {
      try {
        encrypted = safeStorage.encryptString(JSON.stringify(persisted));
      } catch {
        // Availability can change between the preflight and encryption itself.
      }
    }
    if (encrypted) {
      await this.writeAtomically(encrypted);
      return v3InternalEnvelope(persisted, encryptedSourceIdentity(encrypted));
    }
    await this.enterMemoryStorage(observed);
    return {
      ...v3InternalEnvelope(persisted, MISSING_SOURCE_IDENTITY),
      storageVersion: null,
    };
  }

  private async enterMemoryStorage(envelope: ReadableStoredSessionEnvelope) {
    if (!this.memoryOnly) {
      await this.removeEnvelopeDurably();
      this.memoryOnly = true;
      this.cached = {
        ...envelope,
        sourceIdentity: MISSING_SOURCE_IDENTITY,
        storageVersion: null,
      };
      log.warn(
        "[secure-store] OS encryption unavailable; Session will remain in memory until app exit"
      );
    }
    return this.cached!;
  }

  private async writeAtomically(encrypted: Buffer) {
    const directory = dirname(this.filePath);
    await this.fileSystem.mkdir(directory);
    const { handle, path: temporaryPath } = await this.openUniqueTemporaryFile();
    let openHandle: SecureSessionFileHandle | undefined = handle;
    let renamed = false;

    try {
      await openHandle.writeFile(encrypted);
      await openHandle.sync();
      await openHandle.close();
      openHandle = undefined;
      await this.fileSystem.rename(temporaryPath, this.filePath);
      renamed = true;
      await this.syncDirectory(directory);
    } catch (error) {
      if (renamed) this.diskStateUncertain = true;
      throw error;
    } finally {
      if (openHandle) {
        await openHandle.close().catch(() => {});
      }
      if (!renamed) {
        await this.fileSystem.remove(temporaryPath).catch(() => {
          log.warn("[secure-store] failed to remove temporary session envelope");
        });
      }
    }
  }

  private async openUniqueTemporaryFile() {
    const directory = dirname(this.filePath);
    const targetName = basename(this.filePath);
    let collision: unknown;

    for (let attempt = 0; attempt < TEMP_OPEN_ATTEMPTS; attempt += 1) {
      const path = join(
        directory,
        `.${targetName}.${process.pid}.${this.randomId()}.tmp`
      );
      try {
        const handle = await this.fileSystem.open(path, "wx", 0o600);
        return { handle, path };
      } catch (error) {
        if (errorCode(error) !== "EEXIST") throw error;
        collision = error;
      }
    }

    throw collision ?? new Error("Could not create a unique session envelope.");
  }

  private async removeEnvelopeDurably() {
    const directory = dirname(this.filePath);
    await this.fileSystem.remove(this.filePath);
    try {
      await this.syncDirectory(directory);
    } catch (error) {
      if (errorCode(error) === "ENOENT") return;
      this.diskStateUncertain = true;
      throw error;
    }
  }

  private async syncDirectory(directory: string) {
    if (this.platform === "win32") return;

    let handle: SecureSessionFileHandle | undefined;
    try {
      handle = await this.fileSystem.open(directory, "r");
      await handle.sync();
    } catch (error) {
      if (!directorySyncUnsupported(error)) throw error;
    } finally {
      await handle?.close().catch(() => {});
    }
  }

  private enqueueMutation<T>(task: () => Promise<T>): Promise<T> {
    this.assertInitialized();
    const previous = writerTails.get(this.filePath) ?? Promise.resolve();
    const result = previous.then(task);
    const tail = result.then(
      () => undefined,
      () => undefined
    );
    writerTails.set(this.filePath, tail);
    void tail.finally(() => {
      if (writerTails.get(this.filePath) === tail) {
        writerTails.delete(this.filePath);
      }
    });
    return result;
  }

  private commitEnvelope(envelope: ReadableStoredSessionEnvelope) {
    this.cached = envelope;
    this.indeterminateProblem = undefined;
    this.diskStateUncertain = false;
    this.revision += 1;
  }

  private adoptEnvelope(envelope: ReadableStoredSessionEnvelope, publish: boolean) {
    const changed = !storedEnvelopesEqual(this.cached ?? emptyEnvelope(), envelope);
    this.cached = envelope;
    this.indeterminateProblem = undefined;
    this.diskStateUncertain = false;
    if (publish && changed) this.revision += 1;
  }

  private unreadableError(operation: "authenticate" | "reconcile" | "sign_out") {
    const problem = this.diskStateUncertain
      ? createSessionProblem("credential_mutation_uncertain", operation)
      : (this.indeterminateProblem ??
        createSessionProblem("credential_store_unreadable", operation));
    return new SecureSessionStoreError(UNREADABLE_SESSION_ERROR, {
      ...problem,
      operation,
    });
  }

  private assertInitialized() {
    if (!this.initialized) throw new Error(UNINITIALIZED_SESSION_ERROR);
  }
}

function emptyEnvelope(): ReadableStoredSessionEnvelope {
  return {
    pendingRevocations: [],
    sourceIdentity: MISSING_SOURCE_IDENTITY,
    storageVersion: null,
    vaultRevision: 0,
  };
}

function v3InternalEnvelope(
  envelope: StoredSessionEnvelopeV3,
  sourceIdentity: string
): ReadableStoredSessionEnvelope {
  return {
    ...(envelope.active
      ? {
          active: {
            ...envelope.active,
            credentialVersion: 3 as const,
          },
        }
      : {}),
    pendingRevocations: envelope.pendingRevocations.map(clonePending),
    sourceIdentity,
    storageVersion: 3,
    vaultRevision: envelope.vaultRevision,
  };
}

function parseSecureSessionInput(
  input: SecureSessionInput
): SecureSessionActiveCredential {
  return secureSessionActiveCredentialSchema.parse({
    audience: canonicalizeSessionAudience(input.audience),
    email: input.email,
    expiresAtEpochSeconds: input.expiresAtEpochSeconds,
    sessionId: input.sessionId,
    token: input.token,
    userId: input.userId,
  });
}

function parsePendingRevocationInput(
  input: PendingSessionRevocationInput
): SecurePendingSessionRevocationRecord {
  return securePendingSessionRevocationSchema.parse({
    audience: canonicalizeSessionAudience(input.audience),
    ...(input.sessionId ? { sessionId: input.sessionId } : {}),
    token: input.token,
  });
}

function parseVaultContents(
  value: SecureSessionVaultContents
): SecureSessionVaultContents {
  const schema = z.strictObject({
    active: secureSessionActiveCredentialSchema.optional(),
    pendingRevocations: z
      .array(securePendingSessionRevocationSchema)
      .max(MAX_PENDING_REVOCATIONS),
  });
  return schema.parse(value);
}

function storedActiveCredential(
  active: SecureSessionVaultActive | undefined
): SecureSessionActiveCredential | undefined {
  if (!active) return undefined;
  const { credentialVersion: _, ...credential } = active;
  return secureSessionActiveCredentialSchema.parse(credential);
}

function appendPendingRevocation(
  pending: SecurePendingSessionRevocationRecord[],
  next: SecurePendingSessionRevocationRecord
) {
  if (pending.some((candidate) => samePendingIdentity(candidate, next))) {
    return pending;
  }
  if (pending.length >= MAX_PENDING_REVOCATIONS) {
    throw new Error("Pending Session revocation queue is full.");
  }
  return [...pending, next];
}

function pendingMatchesCompletion(
  pending: SecurePendingSessionRevocationRecord,
  completion: {
    audience?: string | undefined;
    sessionId?: string | undefined;
    token: string;
  }
) {
  return (
    pending.token === completion.token &&
    (completion.audience === undefined || pending.audience === completion.audience) &&
    (completion.sessionId === undefined || pending.sessionId === completion.sessionId)
  );
}

function samePendingIdentity(
  left: SecurePendingSessionRevocationRecord,
  right: {
    audience: string;
    sessionId?: string | undefined;
    token: string;
  }
) {
  return (
    left.token === right.token &&
    left.audience === right.audience &&
    left.sessionId === right.sessionId
  );
}

function pendingMatchesActive(
  pending: SecurePendingSessionRevocationRecord,
  active: SecureSessionVaultActive
) {
  return (
    pending.token === active.token &&
    pending.audience === active.audience &&
    (pending.sessionId === undefined || pending.sessionId === active.sessionId)
  );
}

function sameActiveCredentialIdentity(
  left: SecureSessionActiveCredential,
  right: SecureSessionActiveCredential
) {
  return (
    left.token === right.token &&
    left.audience === right.audience &&
    left.sessionId === right.sessionId
  );
}

function clonePending(
  pending: SecurePendingSessionRevocationRecord
): SecurePendingSessionRevocationRecord {
  return {
    audience: pending.audience,
    ...(pending.sessionId ? { sessionId: pending.sessionId } : {}),
    token: pending.token,
  };
}

function cloneActive(active: SecureSessionVaultActive): SecureSessionVaultActive {
  return { ...active };
}

function cleanupFor(pending: SecurePendingSessionRevocationRecord[]): SessionCleanup {
  return sessionCleanupSchema.parse(
    pending.length > 0
      ? { pendingCount: pending.length, revocation: "pending" }
      : { revocation: "idle" }
  );
}

function indeterminateVaultSnapshot(
  problem: SessionProblem
): SecureSessionVaultSnapshot {
  return {
    cleanup: { revocation: "unknown" },
    problem: sessionProblemSchema.parse(problem),
    status: "indeterminate",
  };
}

function incrementVaultRevision(value: number) {
  if (!Number.isSafeInteger(value) || value >= Number.MAX_SAFE_INTEGER) {
    throw new Error("Secure Session vault revision is exhausted; replace the vault.");
  }
  return value + 1;
}

function encryptedSourceIdentity(encrypted: Uint8Array) {
  return createHash("sha256").update(encrypted).digest("base64url");
}

function storedEnvelopesEqual(
  left: ReadableStoredSessionEnvelope,
  right: ReadableStoredSessionEnvelope
) {
  if (
    left.storageVersion !== right.storageVersion ||
    Boolean(left.active) !== Boolean(right.active)
  ) {
    return false;
  }
  if (
    left.active &&
    right.active &&
    JSON.stringify(left.active) !== JSON.stringify(right.active)
  ) {
    return false;
  }
  return (
    left.pendingRevocations.length === right.pendingRevocations.length &&
    left.pendingRevocations.every((pending, index) =>
      samePendingIdentity(pending, right.pendingRevocations[index]!)
    )
  );
}

function directorySyncUnsupported(error: unknown) {
  return ["EBADF", "EINVAL", "EISDIR", "ENOTSUP", "EPERM"].includes(
    errorCode(error) ?? ""
  );
}

function errorCode(error: unknown) {
  return isRecord(error) && typeof error.code === "string" ? error.code : undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Ported from systems/connector/salix-connect/local_file_index_test.go (same test names).
// read_ref streams a registered local-file snapshot only to the exact live connection identity that owns it.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, symlinkSync, writeFileSync, writeSync, closeSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { Effect } from "effect";
import { applyConfigFile, defaultConfig, normalizeConfig } from "../../src/connector/config.ts";
import {
  LOCAL_FILE_CHUNK_BYTES,
  LOCAL_FILE_MAX_BYTES,
  LOCAL_FILE_STREAM_LEASE_MS,
  LocalFileUnavailable,
  openPinnedLocalFileIndex,
  readLocalFileIndexRecord,
} from "../../src/connector/local-file-index.ts";
import { EXACT, acking, bind, claim, connectorWith, dispatch } from "./support/connector.ts";
import { tempDir } from "./support/temp.ts";
import { platform } from "../../src/platform/index.ts";

const TOKEN = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

function params(ref: string): Record<string, unknown> {
  return {
    canonical_message_id: "msg1_exact",
    connection_generation: 17,
    connector_run_id: "run_exact",
    expected_max_bytes: LOCAL_FILE_MAX_BYTES,
    local_file_ref: ref,
    owner_user_id: "user_exact",
    stream_lease_ms: LOCAL_FILE_STREAM_LEASE_MS,
    stable_device_id: "dev_exact",
  };
}

function fixtureWithRef(root: string, ref: string, bytes: Buffer, state: string, owner?: string): void {
  chmodSync(root, 0o700);
  const objectId = ref.replace(/^lfi1_/, "");
  mkdirSync(join(root, "entries"), { recursive: true, mode: 0o700 });
  mkdirSync(join(root, "objects"), { recursive: true, mode: 0o700 });
  const record: Record<string, unknown> = {
    created_at_ms: 1,
    display_name: "fixture.bin",
    local_file_ref: ref,
    media_type: "application/octet-stream",
    object_id: objectId,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    size: bytes.length,
    state,
    version: owner === undefined ? 1 : 2,
  };
  if (owner !== undefined) record.owner_user_id = owner;
  writeFileSync(join(root, "objects", objectId), bytes, { mode: 0o600 });
  writeFileSync(join(root, "entries", `${objectId}.json`), JSON.stringify(record), { mode: 0o600 });
}

function fixture(root: string, bytes: Buffer, state: string, owner?: string): string {
  const ref = `lfi1_${TOKEN}`;
  fixtureWithRef(root, ref, bytes, state, owner);
  return ref;
}

const run = <A, E>(effect: Effect.Effect<A, E>) => Effect.runPromise(effect);

test("TestReadRefStreamsOnlyManagedSnapshotForExactLiveIdentity", async () => {
  const root = tempDir();
  const ref = fixture(root, Buffer.from("immutable".repeat(40_000)), "registered");
  await run(readLocalFileIndexRecord(root, ref));
  const c = connectorWith({ localFileIndexRoot: root });
  const chunks: Buffer[] = [];
  const session = claim(c, acking((frame) => {
    if (frame.stream?.channel === "data" && frame.stream.data) chunks.push(Buffer.from(frame.stream.data, "base64"));
  }));
  assert.ok(bind(c, session));
  const outcome = await dispatch(c, session, "request-1", "read_ref", params(ref));
  assert.ok(outcome.ok, String(!outcome.ok && outcome.error));
  const streamed = Buffer.concat(chunks);
  const result = outcome.result as Record<string, unknown>;
  assert.equal(result.size, streamed.length);
  assert.ok(streamed.toString().startsWith("immutable"));
  const encoded = JSON.stringify(result);
  assert.ok(!encoded.includes(root) && !encoded.includes("path"), `read_ref result leaked a host path: ${encoded}`);
  session.close("canceled");
});

test("TestReadRefAcceptsV2IndexOnlyForItsExactOwner", async () => {
  const root = tempDir();
  const ref = fixture(root, Buffer.from("private owner bytes"), "registered", "user_exact");
  const record = await run(readLocalFileIndexRecord(root, ref));
  assert.equal(record.version, 2);
  assert.equal(record.ownerUserId, "user_exact");
  const c = connectorWith({ localFileIndexRoot: root });
  const session = claim(c, acking());
  bind(c, session);
  assert.ok((await dispatch(c, session, "v2-owner", "read_ref", params(ref))).ok, "exact-owner V2 ref was rejected");
  fixtureWithRef(root, ref, Buffer.from("private owner bytes"), "registered", "user_other");
  assert.ok(!(await dispatch(c, session, "v2-foreign", "read_ref", params(ref))).ok, "foreign-owner V2 ref was accepted");
  session.close("canceled");
});

test("TestLocalFileIndexKeepsStrictV1CompatibilityAndRejectsUnknownV2Shape", async () => {
  const root = tempDir();
  const ref = fixture(root, Buffer.from("legacy"), "registered");
  assert.equal((await run(readLocalFileIndexRecord(root, ref))).version, 1);
  fixtureWithRef(root, ref, Buffer.from("v2"), "registered", "user_exact");
  const entry = join(root, "entries", `${TOKEN}.json`);
  const raw = JSON.parse(readFileSync(entry, "utf8"));
  raw.unknown = true;
  writeFileSync(entry, JSON.stringify(raw), { mode: 0o600 });
  await assert.rejects(run(readLocalFileIndexRecord(root, ref)), "V2 record with an unknown key was accepted");
  delete raw.unknown;
  raw.version = 3;
  writeFileSync(entry, JSON.stringify(raw), { mode: 0o600 });
  await assert.rejects(run(readLocalFileIndexRecord(root, ref)), "unknown local index version was accepted");
});

test("TestReadRefNeverSignalsEOFAfterSnapshotMutatesDuringStream", async () => {
  const root = tempDir();
  const ref = fixture(root, Buffer.alloc(LOCAL_FILE_CHUNK_BYTES * 2, "A"), "registered");
  const objectPath = join(root, "objects", TOKEN);
  const c = connectorWith({ localFileIndexRoot: root });
  let mutated = false;
  let sawEOF = false;
  const session = claim(c, acking((frame) => {
    if (frame.stream?.channel !== "data") return;
    if (frame.stream.eof) sawEOF = true;
    if (frame.stream.data && !mutated) {
      mutated = true;
      const fd = openSync(objectPath, "r+");
      writeSync(fd, Buffer.alloc(LOCAL_FILE_CHUNK_BYTES, "B"), 0, LOCAL_FILE_CHUNK_BYTES, LOCAL_FILE_CHUNK_BYTES);
      closeSync(fd);
    }
  }));
  bind(c, session);
  assert.ok(!(await dispatch(c, session, "mutated", "read_ref", params(ref))).ok, "mutation during stream was accepted");
  assert.ok(mutated, "test did not mutate the streamed snapshot");
  assert.ok(!sawEOF, "stream signaled EOF before terminal size/hash validation");
  session.close("canceled");
});

test("TestReadRefNeverSignalsEOFAfterConnectionReplacement", async () => {
  const root = tempDir();
  const ref = fixture(root, Buffer.from("one frame"), "registered");
  const c = connectorWith({ localFileIndexRoot: root });
  let replacement: ReturnType<typeof claim> | undefined;
  let sawEOF = false;
  const old = claim(c, (frame) => {
    if (frame.stream?.channel !== "data") return;
    if (frame.stream.eof) sawEOF = true;
    if (frame.stream.data && replacement === undefined) replacement = claim(c);
  });
  bind(c, old);
  assert.ok(!(await dispatch(c, old, "replaced", "read_ref", params(ref))).ok, "replaced connection completed its read");
  assert.ok(replacement, "test did not replace the connection");
  assert.ok(!sawEOF, "replaced connection signaled EOF before exact terminal validation");
  replacement.close("canceled");
});

test("TestReadRefFailsClosedForIdentityShapeRevocationAndBounds", async () => {
  const root = tempDir();
  const ref = fixture(root, Buffer.from("secret"), "registered");
  const c = connectorWith({ localFileIndexRoot: root });
  const session = claim(c, acking());
  bind(c, session);
  const mutations: Array<(p: Record<string, unknown>) => void> = [
    (p) => (p.owner_user_id = "user_other"),
    (p) => (p.stable_device_id = "dev_other"),
    (p) => (p.connector_run_id = "run_other"),
    (p) => (p.connection_generation = 18),
    (p) => (p.stream_lease_ms = LOCAL_FILE_STREAM_LEASE_MS + 1),
    (p) => (p.path = "/etc/passwd"),
    (p) => (p.expected_max_bytes = 5),
  ];
  for (const [index, mutate] of mutations.entries()) {
    const p = params(ref);
    mutate(p);
    assert.ok(!(await dispatch(c, session, "rejected", "read_ref", p)).ok, `mutation ${index} was accepted`);
  }
  fixtureWithRef(root, ref, Buffer.from("secret"), "revoked");
  assert.ok(!(await dispatch(c, session, "revoked", "read_ref", params(ref))).ok, "revoked ref was accepted");
  fixtureWithRef(root, ref, Buffer.from("secret"), "draft");
  assert.ok(!(await dispatch(c, session, "draft", "read_ref", params(ref))).ok, "unregistered draft ref was accepted");
  fixtureWithRef(root, ref, Buffer.from("secret"), "bound");
  assert.ok((await dispatch(c, session, "bound", "read_ref", params(ref))).ok, "canonical-bound ref was rejected");
  session.close("canceled");
});

test("TestReadRefRejectsSymlinkAndReplacementConnection", async () => {
  const root = tempDir();
  const ref = fixture(root, Buffer.from("secret"), "registered");
  const c = connectorWith({ localFileIndexRoot: root });
  const old = claim(c);
  bind(c, old);
  const fresh = claim(c, acking());
  assert.ok(!(await dispatch(c, old, "old", "read_ref", params(ref))).ok, "replaced connection read was accepted");
  const objectPath = join(root, "objects", TOKEN);
  const outside = join(tempDir(), "outside");
  writeFileSync(outside, "outside", { mode: 0o600 });
  rmSync(objectPath);
  symlinkSync(outside, objectPath);
  bind(c, fresh, EXACT);
  assert.ok(!(await dispatch(c, fresh, "symlink", "read_ref", params(ref))).ok, "symlink object was accepted");
  fresh.close("canceled");
});

test("TestPinnedLocalFileIndexDoesNotFollowRenamedRoot", async () => {
  const root = tempDir();
  const ref = fixture(root, Buffer.from("trusted"), "registered");
  const index = await run(openPinnedLocalFileIndex(root));
  try {
    const moved = `${root}-moved`;
    renameSync(root, moved);
    const outside = tempDir();
    fixtureWithRef(outside, ref, Buffer.from("attacker"), "registered");
    symlinkSync(outside, root);
    await assert.rejects(run(openPinnedLocalFileIndex(root)), "symlinked replacement root was accepted");
    if (platform.opensDirectories) {
      const record = await run(index.readRecord(ref));
      const bytes = await run(index.readObject(record.objectId));
      assert.equal(bytes.toString(), "trusted", "pinned index escaped to replacement root");
    } else {
      // Pinned by identity (Windows): the root it was is gone from its path, so nothing is read, not the replacement.
      await assert.rejects(run(index.readRecord(ref)), LocalFileUnavailable, "pinned index escaped to replacement root");
    }
    rmSync(root);
    rmSync(moved, { recursive: true, force: true });
  } finally {
    await run(index.close());
  }
});

test("TestLocalFileIndexConfigAndCapabilityAreLocalOnly", async () => {
  const root = join(tempDir(), "local-file-index");
  const configPath = join(tempDir(), "connector.json");
  writeFileSync(configPath, JSON.stringify({ connector: { root: "." }, electron: { local_file_index_root: root } }), { mode: 0o600 });
  const cfg = { ...defaultConfig(), configPath };
  await run(applyConfigFile(cfg, new Set()));
  normalizeConfig(cfg);
  assert.equal(cfg.localFileIndexRoot, root);
  assert.ok(connectorWith({ localFileIndexRoot: root }).localFileImportAvailable(), "local_file_import_v1 capability should be enabled");
});

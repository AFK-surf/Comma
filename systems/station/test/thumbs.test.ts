// Thumbnails and ThumbHashes (src/sessions/thumbs.ts, the addon's native/mesh/src/thumbs.rs): thumbs.rs's tests, and
// the same answers as the Rust station: GET /sessions/:key/files?thumb=1 gives the very bytes the Rust gives, and a
// message keeps the same ThumbHashes. What the Rust gives is test/fixtures/thumbs/golden.json, written by the Rust
// station's own code (the Rust station's thumbs_golden.rs, which also wrote the JPEG and WebP fixtures; the PNGs are made
// here with the same pixels).
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { crc32, deflateSync } from "node:zlib";
import { Admin } from "../src/api/admin.ts";
import type { Request } from "../src/api/request.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { loadMesh } from "../src/mesh/native.ts";
import { Readers } from "../src/read/pool.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub } from "../src/sessions/hub.ts";
import { sizeOf } from "../src/sessions/image-size.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { SMALL, dir, idOf, keep, kept, thumbnail, wanted } from "../src/sessions/thumbs.ts";
import { Store } from "../src/store/store.ts";
import type { Attachment } from "../src/store/rows.ts";
import { FakeDriver } from "./hub-fakes.ts";
import { fileURLToPath } from "node:url";

const fixtures = fileURLToPath(new URL("./fixtures/thumbs/", import.meta.url));
const golden = JSON.parse(readFileSync(join(fixtures, "golden.json"), "utf8")) as Record<
  string,
  { thumbnail: { type: string; sha256: string; bytes: number; width: number; height: number } | null; thumbhash: string | null }
>;
const codecs = loadMesh();

/// A PNG of `w`×`h` pixels, RGB or RGBA (what `pixel` gives), unfiltered.
function png(w: number, h: number, pixel: (x: number, y: number) => number[]): Buffer {
  const channels = pixel(0, 0).length;
  const raw = Buffer.alloc(h * (1 + w * channels));
  let at = 0;
  for (let y = 0; y < h; y++) {
    raw[at++] = 0;
    for (let x = 0; x < w; x++) for (const v of pixel(x, y)) raw[at++] = v & 255;
  }
  const chunk = (type: string, data: Buffer) => {
    const head = Buffer.alloc(8);
    head.writeUInt32BE(data.length, 0);
    head.write(type, 4, "latin1");
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])) >>> 0, 0);
    return Buffer.concat([head, data, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = channels === 4 ? 6 : 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

/// thumbs.rs's tests' `noisy`.
const noisy = (w: number, h: number) => png(w, h, (x, y) => [x * 7 + y * 13, x ^ y, x * y]);

/// The images thumbs_golden.rs makes, made here; the rest are its fixtures.
function testImages(into: string) {
  mkdirSync(into, { recursive: true });
  writeFileSync(join(into, "shot.png"), noisy(1200, 800));
  writeFileSync(join(into, "tall.png"), noisy(500, 1500));
  writeFileSync(join(into, "cut.png"), png(1000, 1000, (x, y) => [x * 7, y * 3, x ^ y, x < 500 ? 0 : 255]));
  writeFileSync(join(into, "icon.png"), noisy(64, 64));
  writeFileSync(join(into, "clear.png"), png(80, 40, (x) => [200, 60, 20, x < 40 ? 0 : 255]));
  writeFileSync(join(into, "broken.png"), Buffer.alloc(200 * 1024, 7));
  writeFileSync(join(into, "moving.gif"), Buffer.alloc(200 * 1024, 0));
  writeFileSync(join(into, "notes.txt"), "hi");
  for (const name of ["photo.jpg", "photo-small.jpg", "icon.webp", "wide.webp"]) copyFileSync(join(fixtures, name), join(into, name));
}

/// thumbhash's `thumb_hash_to_approximate_aspect_ratio`.
function aspect(hash: Buffer): number {
  const header = hash[3]!;
  const alpha = (hash[2]! & 0x80) !== 0;
  const landscape = (hash[4]! & 0x80) !== 0;
  const lx = landscape ? (alpha ? 5 : 7) : header & 7;
  const ly = landscape ? header & 7 : alpha ? 5 : 7;
  return lx / ly;
}

const sha256 = (b: Buffer) => createHash("sha256").update(b).digest("hex");
const sent = (path: string): Attachment => ({ name: path.split("/").at(-1)!, path, size: 0 });

/// Looks every 20 ms until `f` holds: a thumbnail is made in the background, on the file system. No deadline (it
/// comes, however slow the machine, or the test hangs).
async function until(_what: string, f: () => boolean) {
  while (!f()) await new Promise((r) => setTimeout(r, 20));
}

test("which files: png, jpg, jpeg and webp, by name", () => {
  assert.deepEqual(["a.PNG", "b.jpg", "c.Jpeg", "d.webp", "e.gif", "f.svg", "png"].map(wanted), [true, true, true, true, false, false, false]);
  assert.equal(dir("/d"), join("/d", "thumbs"));
  assert.equal(SMALL, 24 * 1024);
  // The first 16 bytes of the SHA-256 of the path.
  assert.equal(idOf("/w/uploads/a.png"), sha256(Buffer.from("/w/uploads/a.png")).slice(0, 32));
});

test("makes a small jpeg of a big screenshot once", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-"));
  try {
    const src = join(tmp, "shot.png");
    writeFileSync(src, noisy(2400, 1600));
    const thumbs = join(tmp, "thumbs");
    const made = await thumbnail(src, thumbs, codecs);
    assert.equal(made?.type, "image/jpeg");
    assert.equal(made.path, join(thumbs, `${idOf(src)}.jpg`));
    assert.deepEqual(sizeOf(readFileSync(made.path)), [720, 480]);
    assert.ok(statSync(made.path).size < statSync(src).size);
    // Kept: asked again, the same file.
    const modified = statSync(made.path).mtimeMs;
    assert.equal((await thumbnail(src, thumbs, codecs))?.path, made.path);
    assert.equal(statSync(made.path).mtimeMs, modified);
    assert.deepEqual(kept(thumbs, idOf(src)), made);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("keeps clear parts clear", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-"));
  try {
    const src = join(tmp, "cut.png");
    writeFileSync(src, png(1600, 1600, (x, y) => [x * 7, y * 3, x ^ y, x < 800 ? 0 : 255]));
    const made = await thumbnail(src, join(tmp, "thumbs"), codecs);
    assert.equal(made?.type, "image/png");
    // RGBA (colour type 6).
    assert.equal(readFileSync(made.path)[25], 6);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("leaves small images and others alone", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-"));
  try {
    const thumbs = join(tmp, "thumbs");
    writeFileSync(join(tmp, "icon.png"), noisy(64, 64));
    assert.equal(await thumbnail(join(tmp, "icon.png"), thumbs, codecs), null);
    writeFileSync(join(tmp, "moving.gif"), Buffer.alloc(200 * 1024));
    assert.equal(await thumbnail(join(tmp, "moving.gif"), thumbs, codecs), null);
    writeFileSync(join(tmp, "broken.png"), Buffer.alloc(200 * 1024, 7));
    assert.equal(await thumbnail(join(tmp, "broken.png"), thumbs, codecs), null);
    assert.equal(await thumbnail(join(tmp, "missing.png"), thumbs, codecs), null);
    // Without the codecs, every image is shown itself.
    writeFileSync(join(tmp, "shot.png"), noisy(400, 400));
    assert.equal(await thumbnail(join(tmp, "shot.png"), thumbs, null), null);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("gives images a thumbhash and makes their thumbnails", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-"));
  try {
    const [big, small, clear] = [join(tmp, "shot.png"), join(tmp, "icon.webp"), join(tmp, "cut.png")];
    writeFileSync(big, noisy(2400, 1600));
    copyFileSync(join(fixtures, "icon.webp"), small);
    writeFileSync(clear, png(80, 40, (x) => [200, 60, 20, x < 40 ? 0 : 255]));
    const notes = join(tmp, "notes.txt");
    writeFileSync(notes, "hi");
    const broken = join(tmp, "broken.jpg");
    writeFileSync(broken, Buffer.alloc(1024, 7));
    const thumbs = join(tmp, "thumbs");
    const files = await keep([sent(big), sent(small), sent(clear), sent(notes), sent(broken)], thumbs, codecs);
    for (const file of files.slice(0, 3)) {
      const bytes = Buffer.from(file.thumbhash!, "base64");
      assert.ok(bytes.length < 40, `${file.name}: ${bytes.length} bytes`);
      // Its shape comes with it, roughly (more roughly with clear parts).
      const [w, h] = sizeOf(readFileSync(file.path))!;
      assert.ok(Math.abs(aspect(bytes) / (w / h) - 1) < 0.25, `${file.name}: ${aspect(bytes)}`);
    }
    assert.deepEqual([files[3]!.thumbhash, files[4]!.thumbhash], [undefined, undefined]);
    assert.deepEqual(files[3], sent(notes));
    // The big one's thumbnail comes after, as if asked for.
    await until("the big one's thumbnail", () => kept(thumbs, idOf(big)) !== null);
    assert.equal(kept(thumbs, idOf(big))!.type, "image/jpeg");
    assert.equal(kept(thumbs, idOf(small)), null);
    // None wanted, or no codecs: as they came.
    const plain = [sent(notes)];
    assert.equal(await keep(plain, thumbs, codecs), plain);
    assert.deepEqual(await keep([sent(big)], thumbs, null), [sent(big)]);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("turns a photo as its camera says", async () => {
  // A 40×20 JPEG whose EXIF says it is seen turned a quarter (orientation 6): 20×40.
  const seen = await codecs.thumbhash(join(fixtures, "photo-small.jpg"));
  assert.deepEqual([seen?.width, seen?.height], [20, 40]);
  assert.equal(seen!.hash, golden["photo-small.jpg"]!.thumbhash);
});

test("the files route and a message give what the Rust station gives", async () => {
  const data = mkdtempSync(join(tmpdir(), "thumbs-r-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const config = hubConfig({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }] }, data);
  const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [new FakeDriver("claude")], mcpUrl: "http://127.0.0.1:1/mcp", internal: new InternalChat(), runners: () => [] });
  const jobs = new Jobs({ store, data, notify: () => {}, link: () => null });
  hub.setJobs(jobs);
  const readers = new Readers(data, 1);
  readers.processes = () => hub.processes();
  const admin = new Admin(readers, { store, agents: { hub, jobs } as any });
  const viewer = { sub: "u", email: "a@x", name: "A", role: "member", workspace: "w", device: "d" };
  const ask = (method: string, path: string, body = "", query: [string, string][] = []) =>
    admin.handle({ method, path, query, headers: {}, body: Buffer.from(body), viewer, lang: "en" } satisfies Request);
  try {
    const made = JSON.parse(String((await ask("POST", "/sessions", JSON.stringify({ runtime: "claude" }))).body));
    const uploads = join(store.getSession(made.key)!.workspace, "uploads");
    testImages(uploads);
    const names = Object.keys(golden);
    const thumbs = join(data, "thumbs");
    const kinds: Record<string, string> = { png: "image/png", jpg: "image/jpeg", webp: "image/webp", gif: "image/gif", txt: "text/plain; charset=utf-8" };
    const fileOf = async (name: string, thumb: boolean) => {
      const a = await ask("GET", `/sessions/${encodeURIComponent(made.key)}/files`, "", thumb ? [["name", name], ["thumb", "1"]] : [["name", name]]);
      assert.equal(a.status, 200, name);
      assert.equal(a.headers["cache-control"], "private, max-age=3600", name);
      return [a.headers["content-type"], a.body as Buffer] as const;
    };
    for (const name of names) {
      const want = golden[name]!.thumbnail;
      const original = readFileSync(join(uploads, name));
      // Made on first asking (an image kept before thumbnails were made), then as kept.
      for (const time of ["made", "kept"]) {
        const [type, body] = await fileOf(name, true);
        if (want === null) assert.deepEqual([type, sha256(body)], [kinds[name.split(".").at(-1)!], sha256(original)], `${name} (${time}): the image itself`);
        else assert.deepEqual([type, sha256(body), body.length, sizeOf(body)], [want.type, want.sha256, want.bytes, [want.width, want.height]], `${name} (${time})`);
      }
      // Without thumb=1, the image itself.
      assert.equal(sha256((await fileOf(name, false))[1]), sha256(original), name);
    }

    // A message keeps each image's ThumbHash; an image's thumbnail is made after (the files route made them all above,
    // so they go first).
    rmSync(thumbs, { recursive: true, force: true });
    const attachments = names.map((name) => ({ path: join(uploads, name), name }));
    const posted = await ask("POST", `/threads/${made.thread.id}/messages`, JSON.stringify({ text: "look", attachments }));
    assert.equal(posted.status, 200, String(posted.body));
    const message = store.messagesBefore(made.thread.id, null, 10).find((m) => m.n === JSON.parse(String(posted.body)).n)!;
    assert.deepEqual(
      message.attachments.map((a) => [a.name, a.thumbhash ?? null]),
      names.map((name) => [name, golden[name]!.thumbhash]),
    );
    for (const name of names) {
      const want = golden[name]!.thumbnail;
      const id = idOf(join(uploads, name));
      if (want === null) continue;
      await until(`${name}'s thumbnail`, () => kept(thumbs, id) !== null);
      const got = kept(thumbs, id)!;
      assert.deepEqual([got.type, sha256(readFileSync(got.path))], [want.type, want.sha256], name);
    }
    // Small, other or unreadable images get none.
    for (const name of names.filter((n) => golden[n]!.thumbnail === null)) assert.equal(kept(thumbs, idOf(join(uploads, name))), null, name);
  } finally {
    await hub.shutdown();
    await jobs.shutdown();
    readers.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

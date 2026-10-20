// What the native addon does as the Rust station did (native/mesh/src/local.rs): local links read with pulldown-cmark
// (raw HTML and indented code blocks are not links). The archive lock held across processes is side/native-extras.test.ts.
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { prepare } from "../src/sessions/local-links.ts";

test("local links are read as pulldown-cmark reads them", () => {
  const dir = mkdtempSync(join(tmpdir(), "links-"));
  const file = join(dir, "report.pdf");
  writeFileSync(file, "x");
  const paths: string[] = [];
  const text = `See [the report](${file}).\n\n<a href="${file}">raw html</a>\n\n    [indented](${file})\n`;
  const out = prepare(text, paths, dir);
  assert.deepEqual(paths, [file]);
  assert.ok(out.startsWith("See [the report](report%2Epdf)."), out);
  // The raw HTML and the indented code block are left as they are.
  assert.ok(out.includes(`<a href="${file}">raw html</a>`) && out.includes(`    [indented](${file})`), out);
  assert.throws(() => prepare(`[x](${join(dir, "missing.pdf")})`, [], dir), /does not name a readable file/);
});

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

test("runtime bundle publication is content-addressed and immutable", () => {
  const root = mkdtempSync(join(tmpdir(), "comma-runtime-r2-"));
  const bundleDir = join(root, "dist");
  const transport = join(root, "r2");
  const fakeBin = join(root, "bin");
  mkdirSync(bundleDir);
  mkdirSync(transport);
  mkdirSync(fakeBin);

  const images = ["external", "meeting", "shell"].map((className, index) => {
    const bytes = Buffer.from(`${className}-oci-archive`);
    const sha = createHash("sha256").update(bytes).digest("hex");
    const manifestDigest = `sha256:${String(index + 4).repeat(64)}`;
    writeFileSync(join(bundleDir, `${className}.oci.tar`), bytes);
    return {
      class: className,
      inputDigest: `sha256:${String(index + 1).repeat(64)}`,
      reference: `comma.local/runtime/${className}@${manifestDigest}`,
      platform: "linux/arm64",
      archiveSize: bytes.length,
      archiveSha256: sha,
      manifestDigest,
    };
  });
  writeFileSync(join(bundleDir, "manifest.json"), JSON.stringify({
    schemaVersion: 3,
    sourceRevision: "revision",
    images,
  }));

  const aws = join(fakeBin, "aws");
  writeFileSync(aws, `#!/bin/sh
set -eu
action=""; key=""; body=""; destination=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    head-object|get-object|put-object) action="$1" ;;
    --key) shift; key="$1" ;;
    --body) shift; body="$1" ;;
    --endpoint-url|--bucket|--if-none-match|--content-type|--cache-control) shift ;;
    s3api) ;;
    *) destination="$1" ;;
  esac
  shift
done
object="$FAKE_R2_ROOT/$key"
case "$action" in
  head-object) test -f "$object" ;;
  get-object) cp "$object" "$destination" ;;
  put-object)
    mkdir -p "$(dirname "$object")"
    test ! -e "$object"
    cp "$body" "$object"
    ;;
  *) exit 2 ;;
esac
`);
  chmodSync(aws, 0o755);

  const env = {
    ...process.env,
    PATH: `${fakeBin}:${process.env.PATH}`,
    FAKE_R2_ROOT: transport,
    CLOUDFLARE_R2_ACCOUNT_ID: "test",
    CLOUDFLARE_R2_BUCKET: "test",
    AWS_ACCESS_KEY_ID: "test",
    AWS_SECRET_ACCESS_KEY: "test",
  };
  const script = join(import.meta.dirname, "publish-runtime-bundles.sh");

  try {
    const published = spawnSync("bash", [script, bundleDir], { encoding: "utf8", env });
    assert.equal(published.status, 0, published.stderr);
    for (const image of images) {
      const object = join(transport, "runtime-bundles", "sha256", `${image.archiveSha256}.oci.tar`);
      assert.equal(readFileSync(object, "utf8"), `${image.class}-oci-archive`);
    }

    const repeated = spawnSync("bash", [script, bundleDir], { encoding: "utf8", env });
    assert.equal(repeated.status, 0, repeated.stderr);

    const changed = images[0];
    writeFileSync(join(bundleDir, `${changed.class}.oci.tar`), "mutated local bytes");
    const rejected = spawnSync("bash", [script, bundleDir], { encoding: "utf8", env });
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, /runtime bundle does not match manifest/);
    assert.equal(
      readFileSync(join(transport, "runtime-bundles", "sha256", `${changed.archiveSha256}.oci.tar`), "utf8"),
      `${changed.class}-oci-archive`,
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

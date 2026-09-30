import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { downloadOpenDropKitAsset } from "./opendropkit-release";

async function main() {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: { "from-directory": { type: "string" } },
  });
  const [tag] = positionals;
  if (
    positionals.length !== 1 ||
    !/^v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/u.test(tag ?? "")
  ) {
    throw new Error("Pass a release tag, such as v0.1.0.");
  }
  const local = values["from-directory"];
  let checksums: string;
  if (local) {
    checksums = readFileSync(join(local, "SHA256SUMS"), "utf8");
  } else {
    checksums = (
      await downloadOpenDropKitAsset(tag!, "SHA256SUMS", {
        token: process.env.OPENDROPKIT_RELEASE_TOKEN,
      })
    ).toString("utf8");
  }
  const entries = new Map(
    checksums
      .trim()
      .split(/\r?\n/u)
      .map((line) => {
        const match = /^([a-f0-9]{64})\s+\*?(\S+)$/u.exec(line);
        if (!match) throw new Error("Invalid release checksum entry.");
        return [match[2]!, match[1]!] as const;
      })
  );
  const archives = Object.fromEntries(
    ["arm64", "x64"].map((arch) => {
      const target = arch === "x64" ? "x86_64" : arch;
      const archive = `opendropkit-${tag}-${target}-apple-darwin.tar.gz`;
      const sha256 = entries.get(archive);
      if (!sha256) throw new Error(`Missing checksum for ${archive}.`);
      return [`darwin/${arch}`, { archive, sha256 }];
    })
  );
  writeFileSync(
    join(import.meta.dirname, "opendropkit-release.json"),
    `${JSON.stringify({ tag, archives }, null, 2)}\n`
  );
  console.log(
    `Pinned OpenDropKit ${tag}. Review the release and run build:native:airdrop before committing.`
  );
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
